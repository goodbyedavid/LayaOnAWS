import * as path from "node:path";
import {
  CfnOutput,
  Duration,
  RemovalPolicy,
  Stack,
  StackProps
} from "aws-cdk-lib";
import * as acm from "aws-cdk-lib/aws-certificatemanager";
import * as apigwv2 from "aws-cdk-lib/aws-apigatewayv2";
import * as apigwv2Integrations from "aws-cdk-lib/aws-apigatewayv2-integrations";
import * as autoscaling from "aws-cdk-lib/aws-autoscaling";
import * as ec2 from "aws-cdk-lib/aws-ec2";
import * as ecrAssets from "aws-cdk-lib/aws-ecr-assets";
import * as ecs from "aws-cdk-lib/aws-ecs";
import * as elbv2 from "aws-cdk-lib/aws-elasticloadbalancingv2";
import * as iam from "aws-cdk-lib/aws-iam";
import * as logs from "aws-cdk-lib/aws-logs";
import * as route53 from "aws-cdk-lib/aws-route53";
import * as s3 from "aws-cdk-lib/aws-s3";
import * as route53Targets from "aws-cdk-lib/aws-route53-targets";
import * as secretsmanager from "aws-cdk-lib/aws-secretsmanager";
import { Construct } from "constructs";

export interface LayaVerificationStackProps extends StackProps {
  /** Desired GPU instance and ECS task count. Only 0 or 1 is supported. */
  readonly capacity: number;
  /** Expose Laya through an Amazon API Gateway HTTP API over HTTPS. */
  readonly publicEndpoint: boolean;
  /**
   * Optional custom domain, for example `laya.example.com`. Without it the API
   * is served on its generated `*.execute-api` hostname, which already has a
   * trusted certificate and requires no domain of your own.
   */
  readonly domainName?: string;
  /** Route 53 hosted zone ID, required only with `domainName`. */
  readonly hostedZoneId?: string;
  /** Route 53 hosted zone apex name, required only with `domainName`. */
  readonly hostedZoneName?: string;
  /** Sustained requests per second allowed by API Gateway. */
  readonly rateLimit: number;
  /** Burst requests allowed by API Gateway. */
  readonly burstLimit: number;
  /**
   * Allow the EC2 instance role to read the generated bearer token.
   *
   * This is required only by the host-side benchmark scripts, which fetch the
   * token on the instance so it never travels through SSM command parameters.
   * It is off by default because it means any process on the host, and anyone
   * with SSM shell access to it, can read the API token. Production
   * deployments should leave it off.
   */
  readonly hostBenchmarkAccess: boolean;
}

export class LayaVerificationStack extends Stack {
  constructor(scope: Construct, id: string, props: LayaVerificationStackProps) {
    super(scope, id, props);

    // Two Availability Zones: an Application Load Balancer requires subnets in
    // at least two, and a second AZ also gives the Auto Scaling group a second
    // chance at scarce GPU capacity. Public subnets keep the idle cost at zero
    // because no NAT gateway is required for checkpoint downloads.
    const vpc = new ec2.Vpc(this, "Vpc", {
      maxAzs: 2,
      natGateways: 0,
      subnetConfiguration: [
        {
          name: "laya",
          subnetType: ec2.SubnetType.PUBLIC
        }
      ]
    });

    const instanceSecurityGroup = new ec2.SecurityGroup(this, "InstanceSecurityGroup", {
      vpc,
      description:
        "Laya GPU host. Inbound is allowed only from the load balancer when the " +
        "public endpoint is enabled; otherwise there is no inbound access and " +
        "Laya is reachable only through AWS Systems Manager",
      allowAllOutbound: true
    });

    const cluster = new ecs.Cluster(this, "Cluster", {
      vpc,
      containerInsightsV2: ecs.ContainerInsights.ENABLED
    });

    const instanceRole = new iam.Role(this, "GpuInstanceRole", {
      assumedBy: new iam.ServicePrincipal("ec2.amazonaws.com"),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName("AmazonSSMManagedInstanceCore")
      ]
    });

    const userData = ec2.UserData.forLinux();
    userData.addCommands(
      "echo ECS_ENABLE_GPU_SUPPORT=true >> /etc/ecs/ecs.config",
      "install -d -o 10001 -g 10001 /opt/laya-cache"
    );

    const launchTemplate = new ec2.LaunchTemplate(this, "GpuLaunchTemplate", {
      machineImage: ecs.EcsOptimizedImage.amazonLinux2023(ecs.AmiHardwareType.GPU),
      instanceType: new ec2.InstanceType("g4dn.xlarge"),
      associatePublicIpAddress: true,
      securityGroup: instanceSecurityGroup,
      role: instanceRole,
      userData,
      requireImdsv2: true,
      blockDevices: [
        {
          deviceName: "/dev/xvda",
          volume: ec2.BlockDeviceVolume.ebs(100, {
            encrypted: true,
            deleteOnTermination: true,
            volumeType: ec2.EbsDeviceVolumeType.GP3
          })
        }
      ]
    });

    const autoScalingGroup = new autoscaling.AutoScalingGroup(this, "GpuAutoScalingGroup", {
      vpc,
      vpcSubnets: { subnetType: ec2.SubnetType.PUBLIC },
      launchTemplate,
      minCapacity: 0,
      desiredCapacity: props.capacity,
      maxCapacity: 1
    });

    const capacityProvider = new ecs.AsgCapacityProvider(this, "CapacityProvider", {
      autoScalingGroup,
      enableManagedTerminationProtection: false
    });
    cluster.addAsgCapacityProvider(capacityProvider);

    const imageAsset = new ecrAssets.DockerImageAsset(this, "LayaImage", {
      directory: path.join(__dirname, "..", ".."),
      file: "Dockerfile",
      platform: ecrAssets.Platform.LINUX_AMD64
    });

    const apiKey = new secretsmanager.Secret(this, "ApiKey", {
      description: "Bearer token for the private Laya verification endpoint",
      generateSecretString: {
        passwordLength: 40,
        excludePunctuation: true
      },
      removalPolicy: RemovalPolicy.DESTROY
    });
    // The task execution role always needs this so the container can receive the
    // token. The *instance* role is a separate, wider grant and stays off unless
    // explicitly requested, because it exposes the token to anything running on
    // the host.
    if (props.hostBenchmarkAccess) {
      apiKey.grantRead(autoScalingGroup.role);
    }

    const logGroup = new logs.LogGroup(this, "LogGroup", {
      retention: logs.RetentionDays.ONE_WEEK,
      removalPolicy: RemovalPolicy.DESTROY
    });

    const taskDefinition = new ecs.Ec2TaskDefinition(this, "TaskDefinition", {
      networkMode: ecs.NetworkMode.BRIDGE
    });
    taskDefinition.addVolume({
      name: "model-cache",
      host: { sourcePath: "/opt/laya-cache" }
    });

    const container = taskDefinition.addContainer("Laya", {
      image: ecs.ContainerImage.fromDockerImageAsset(imageAsset),
      cpu: 3072,
      memoryReservationMiB: 8192,
      gpuCount: 1,
      environment: {
        LAYA_DEVICE: "cuda",
        LAYA_PRELOAD: "1",
        LAYA_MODELS: "english,multilingual",
        LAYA_HOST: "0.0.0.0",
        LAYA_PORT: "8000",
        LAYA_LOG_LEVEL: "info",
        HF_HOME: "/home/laya/.cache/huggingface",
        NVIDIA_DRIVER_CAPABILITIES: "compute,utility"
      },
      secrets: {
        LAYA_API_KEY: ecs.Secret.fromSecretsManager(apiKey)
      },
      logging: ecs.LogDrivers.awsLogs({
        logGroup,
        streamPrefix: "laya"
      }),
      healthCheck: {
        command: [
          "CMD-SHELL",
          "python -c \"import torch,urllib.request; assert torch.cuda.is_available(); urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=4)\""
        ],
        interval: Duration.seconds(30),
        timeout: Duration.seconds(5),
        retries: 3,
        startPeriod: Duration.minutes(5)
      }
    });

    container.addPortMappings({
      containerPort: 8000,
      hostPort: 8000,
      protocol: ecs.Protocol.TCP
    });
    container.addMountPoints({
      containerPath: "/home/laya/.cache/huggingface",
      sourceVolume: "model-cache",
      readOnly: false
    });

    const service = new ecs.Ec2Service(this, "Service", {
      cluster,
      taskDefinition,
      desiredCount: props.capacity,
      circuitBreaker: { rollback: true },
      capacityProviderStrategies: [
        {
          capacityProvider: capacityProvider.capacityProviderName,
          weight: 1
        }
      ],
      minHealthyPercent: 0,
      maxHealthyPercent: 100
    });

    if (props.publicEndpoint) {
      this.addPublicEndpoint({
        vpc,
        service,
        instanceSecurityGroup,
        domainName: props.domainName,
        hostedZoneId: props.hostedZoneId,
        hostedZoneName: props.hostedZoneName,
        rateLimit: props.rateLimit,
        burstLimit: props.burstLimit
      });
    }

    new CfnOutput(this, "ClusterName", { value: cluster.clusterName });
    new CfnOutput(this, "ApiKeySecretArn", { value: apiKey.secretArn });
    new CfnOutput(this, "LogGroupName", { value: logGroup.logGroupName });
    new CfnOutput(this, "GpuCapacity", { value: String(props.capacity) });
    new CfnOutput(this, "Connection", {
      value: "Run scripts/connect.sh, then scripts/verify.sh in another terminal"
    });
  }

  /**
   * Fronts the Laya task with an Amazon API Gateway HTTP API.
   *
   * TLS terminates at API Gateway using its generated `*.execute-api` hostname
   * and certificate, so no domain or Route 53 hosted zone is required. A custom
   * domain is optional and only changes the front door; the backend topology is
   * identical either way.
   *
   * The load balancer behind the API is **internal**, reachable only through the
   * VPC link, so nothing in the data path is exposed to the internet and no
   * request crosses the public internet unencrypted.
   *
   * The API uses a `$default` route, which forwards the request path unchanged.
   * That preserves `POST /v1/systemone` so an existing Jev client only repoints
   * its base URL. The `Authorization` header is forwarded untouched, because
   * authentication remains Laya's own bearer token check inside the container.
   *
   * Throttling is done by API Gateway rather than AWS WAF, because WAF cannot be
   * associated with an HTTP API. This matters: Laya serialises inference through
   * one worker, so a request rate limit is the control that actually protects it.
   */
  private addPublicEndpoint(options: {
    vpc: ec2.Vpc;
    service: ecs.Ec2Service;
    instanceSecurityGroup: ec2.SecurityGroup;
    domainName?: string;
    hostedZoneId?: string;
    hostedZoneName?: string;
    rateLimit: number;
    burstLimit: number;
  }): void {
    const {
      vpc,
      service,
      instanceSecurityGroup,
      domainName,
      hostedZoneId,
      hostedZoneName,
      rateLimit,
      burstLimit
    } = options;

    const loadBalancerSecurityGroup = new ec2.SecurityGroup(this, "AlbSecurityGroup", {
      vpc,
      description: "Internal load balancer for the Laya endpoint, reached through the VPC link",
      allowAllOutbound: true
    });

    const vpcLinkSecurityGroup = new ec2.SecurityGroup(this, "VpcLinkSecurityGroup", {
      vpc,
      description: "API Gateway VPC link for the Laya endpoint",
      allowAllOutbound: true
    });

    // The only thing that may reach the load balancer is the VPC link. There is
    // deliberately no CIDR based rule here, because the load balancer is
    // internal and callers arrive through API Gateway.
    loadBalancerSecurityGroup.addIngressRule(
      vpcLinkSecurityGroup,
      ec2.Port.tcp(80),
      "HTTP from the API Gateway VPC link only"
    );

    // The GPU host accepts traffic only from the load balancer.
    instanceSecurityGroup.addIngressRule(
      loadBalancerSecurityGroup,
      ec2.Port.tcp(8000),
      "Laya HTTP from the load balancer only"
    );

    const loadBalancer = new elbv2.ApplicationLoadBalancer(this, "Alb", {
      vpc,
      internetFacing: false,
      securityGroup: loadBalancerSecurityGroup,
      vpcSubnets: { subnetType: ec2.SubnetType.PUBLIC }
    });
    loadBalancer.setAttribute("routing.http.drop_invalid_header_fields.enabled", "true");

    // Access logs are the only record of who called the endpoint. The bucket
    // expires objects so an abandoned deployment cannot accumulate storage cost.
    const accessLogBucket = new s3.Bucket(this, "AlbAccessLogs", {
      encryption: s3.BucketEncryption.S3_MANAGED,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      enforceSSL: true,
      removalPolicy: RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
      lifecycleRules: [{ expiration: Duration.days(30) }]
    });
    loadBalancer.logAccessLogs(accessLogBucket);

    const targetGroup = new elbv2.ApplicationTargetGroup(this, "TargetGroup", {
      vpc,
      port: 8000,
      protocol: elbv2.ApplicationProtocol.HTTP,
      targetType: elbv2.TargetType.INSTANCE,
      // Laya exposes an unauthenticated health route, so the load balancer can
      // probe it without holding a credential.
      healthCheck: {
        path: "/health",
        healthyHttpCodes: "200",
        interval: Duration.seconds(30),
        timeout: Duration.seconds(5),
        healthyThresholdCount: 2,
        unhealthyThresholdCount: 3
      },
      // Inference requests are short. A long drain only slows scale-down.
      deregistrationDelay: Duration.seconds(30)
    });
    targetGroup.addTarget(
      service.loadBalancerTarget({ containerName: "Laya", containerPort: 8000 })
    );

    // `open: false` matters. CDK would otherwise add its own 0.0.0.0/0 ingress
    // rule for the listener, which on an internal load balancer would still
    // widen access to the entire VPC CIDR beyond the VPC link.
    const listener = loadBalancer.addListener("Http", {
      port: 80,
      protocol: elbv2.ApplicationProtocol.HTTP,
      open: false,
      defaultTargetGroups: [targetGroup]
    });

    const vpcLink = new apigwv2.VpcLink(this, "VpcLink", {
      vpc,
      subnets: { subnetType: ec2.SubnetType.PUBLIC },
      securityGroups: [vpcLinkSecurityGroup]
    });

    const httpApi = new apigwv2.HttpApi(this, "HttpApi", {
      description: "Jev-compatible Laya System One endpoint",
      defaultIntegration: new apigwv2Integrations.HttpAlbIntegration(
        "LayaAlbIntegration",
        listener,
        { vpcLink }
      )
    });

    // Rate limiting is the control that protects a single-worker inference
    // server. API Gateway applies these per stage.
    const stage = httpApi.defaultStage?.node.defaultChild as apigwv2.CfnStage;
    stage.defaultRouteSettings = {
      throttlingRateLimit: rateLimit,
      throttlingBurstLimit: burstLimit,
      detailedMetricsEnabled: true
    };

    let endpointHost = `${httpApi.apiId}.execute-api.${this.region}.${this.urlSuffix}`;

    if (domainName && hostedZoneId && hostedZoneName) {
      const hostedZone = route53.HostedZone.fromHostedZoneAttributes(this, "HostedZone", {
        hostedZoneId,
        zoneName: hostedZoneName
      });

      const certificate = new acm.Certificate(this, "Certificate", {
        domainName,
        validation: acm.CertificateValidation.fromDns(hostedZone)
      });

      const apiDomain = new apigwv2.DomainName(this, "ApiDomain", {
        domainName,
        certificate
      });

      new apigwv2.ApiMapping(this, "ApiMapping", {
        api: httpApi,
        domainName: apiDomain,
        stage: httpApi.defaultStage!
      });

      new route53.ARecord(this, "AliasRecord", {
        zone: hostedZone,
        recordName: domainName,
        target: route53.RecordTarget.fromAlias(
          new route53Targets.ApiGatewayv2DomainProperties(
            apiDomain.regionalDomainName,
            apiDomain.regionalHostedZoneId
          )
        )
      });

      endpointHost = domainName;
    }

    new CfnOutput(this, "EndpointUrl", {
      value: `https://${endpointHost}/v1/systemone`,
      description: "Jev-compatible Laya endpoint"
    });
    new CfnOutput(this, "HealthUrl", {
      value: `https://${endpointHost}/health`,
      description: "Unauthenticated health route"
    });
    new CfnOutput(this, "EndpointBaseUrl", {
      value: `https://${endpointHost}`,
      description: "Base URL to point an existing Jev client at"
    });
  }
}
