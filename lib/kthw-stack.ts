import * as cdk from '@aws-cdk/core';
import * as ec2 from '@aws-cdk/aws-ec2';
import * as iam from '@aws-cdk/aws-iam';
import { readFileSync } from 'fs';
import * as path from 'path';

export class KthwStack extends cdk.Stack {
  constructor(scope: cdk.Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    const keyName = 'kthw';
    const bucketName = 'magictraining-bucket';
    const apilbName = 'api-load-balancer';
    const workerCount = parseInt(process.env.WORKER_COUNT || '');
    const numberOfWorkers = Number.isInteger(workerCount) ? workerCount : 1;
    const controllerCount = parseInt(process.env.CONTROLLER_COUNT || '');
    const numberOfControllers = Number.isInteger(controllerCount) ? controllerCount : 1;

    const vpc = new ec2.Vpc(this, 'Vpc', {
      maxAzs: 2,
      cidr: '10.240.0.0/16',
      subnetConfiguration: [
        {
          cidrMask: 24,
          name: 'Default',
          subnetType: ec2.SubnetType.PUBLIC,
        },
      ],
    });

    const AMI =
      '/aws/service/canonical/ubuntu/server/20.04/stable/current/amd64/hvm/ebs-gp2/ami-id';
    const machineImage = ec2.MachineImage.fromSSMParameter(
      AMI,
      ec2.OperatingSystemType.LINUX
    );
    const controllerInstanceType = ec2.InstanceType.of(
      ec2.InstanceClass.BURSTABLE2,
      ec2.InstanceSize.MICRO
    );
    const workerInstanceType = ec2.InstanceType.of(
      ec2.InstanceClass.BURSTABLE2,
      ec2.InstanceSize.MICRO
    );

    const clusterSecurityGroup = new ec2.SecurityGroup(this, 'clusterSG', {
      vpc: vpc,
      allowAllOutbound: true,
      securityGroupName: 'clusterSG',
    });
    clusterSecurityGroup.addIngressRule(
      ec2.Peer.anyIpv4(),
      ec2.Port.tcp(22),
      'Allow external ssh'
    );
    clusterSecurityGroup.addIngressRule(
      ec2.Peer.anyIpv4(),
      ec2.Port.tcp(6443),
      'Allow external api'
    );
    clusterSecurityGroup.addIngressRule(
      ec2.Peer.anyIpv4(),
      ec2.Port.tcp(80),
      'Allow external api'
    );
    clusterSecurityGroup.addIngressRule(
      ec2.Peer.anyIpv4(),
      ec2.Port.allIcmp(),
      'Allow external icmp'
    );

    const internalNetworks = ['10.240.0.0/24', '10.200.0.0/16'];
    for (let i = 0; i < internalNetworks.length; i++) {
      clusterSecurityGroup.addIngressRule(
        ec2.Peer.ipv4(internalNetworks[i]),
        ec2.Port.allTcp(),
        'Allow internal tcp'
      );
      clusterSecurityGroup.addIngressRule(
        ec2.Peer.ipv4(internalNetworks[i]),
        ec2.Port.allUdp(),
        'Allow internal udp'
      );
      clusterSecurityGroup.addIngressRule(
        ec2.Peer.ipv4(internalNetworks[i]),
        ec2.Port.allIcmp(),
        'Allow internal icmp'
      );
    }

    const albRole = new iam.Role(this, 'albrole', {
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
      inlinePolicies: {
        SSHKeyBucket: new iam.PolicyDocument({
          assignSids: true,
          statements: [
            new iam.PolicyStatement({
              effect: iam.Effect.ALLOW,
              actions: ['s3:GetObject'],
              resources: [
                `arn:aws:s3:::${bucketName}/${keyName}.pem`,
                `arn:aws:s3:::${bucketName}/coredns.yaml`,
              ],
            }),
          ],
        }),
      },
    });

    let apilbUserData = readFileSync(
      path.join(__dirname, '../assets/apilbUserData.sh'),
      'utf8'
    );
    apilbUserData = apilbUserData.replace(/BUCKET_NAME/g, bucketName);
    apilbUserData = apilbUserData.replace(/KEY_NAME/g, `${keyName}.pem`);
    apilbUserData = apilbUserData.replace(
      /WORKERS/g,
      new Array(numberOfWorkers)
        .fill(0)
        .map((_, i) => `worker${i}=10.240.0.2${i}`)
        .join(' ')
    );
    apilbUserData = apilbUserData.replace(
      /CONTROLLERS/g,
      new Array(numberOfControllers)
        .fill(0)
        .map((_, i) => `controller${i}=10.240.0.1${i}`)
        .join(' ')
    );
    apilbUserData = apilbUserData.replace(
      /CONTROLLERIPS/g,
      new Array(numberOfControllers)
        .fill(0)
        .map((_, i) => '10.240.0.1' + i)
        .join(',')
    );
    apilbUserData = apilbUserData.replace(
      /NGINXBACKEND/g,
      new Array(numberOfControllers)
        .fill(0)
        .map((_, i) => `server 10.240.0.1${i}:6443;`)
        .join('\n                ')
    );
    console.log(apilbUserData);

    const apilb = new ec2.Instance(this, apilbName, {
      instanceName: apilbName,
      instanceType: controllerInstanceType,
      machineImage: machineImage,
      securityGroup: clusterSecurityGroup,
      vpcSubnets: { subnets: [vpc.publicSubnets[0]] },
      userData: ec2.UserData.custom(apilbUserData),
      sourceDestCheck: true,
      keyName: keyName,
      role: albRole,
      vpc: vpc,
    });

    const kubeRole = new iam.Role(this, 'clusterrole', {
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
      inlinePolicies: {
        SSHKeyBucket: new iam.PolicyDocument({
          assignSids: true,
          statements: [
            new iam.PolicyStatement({
              effect: iam.Effect.ALLOW,
              actions: [
                'ec2:DescribeInstances',
                'ec2:DescribeImages',
                'ec2:DescribeTags',
              ],
              resources: ['*'],
            }),
          ],
        }),
      },
    });

    let controllerUserData = readFileSync(
      path.join(__dirname, '../assets/controllerUserData.sh'),
      'utf8'
    );
    controllerUserData = controllerUserData.replace(/APILBNAME/g, apilbName);
    controllerUserData = controllerUserData.replace(
      /CONTROLLERIPS/g,
      new Array(numberOfControllers)
        .fill(0)
        .map((_, i) => '10.240.0.1' + i)
        .join(',')
    );
    controllerUserData = controllerUserData.replace(
      /ETCDINITIAL/g,
      new Array(numberOfControllers)
        .fill(0)
        .map((_, i) => `controller${i}=https://10.240.0.1${i}:2380`)
        .join(',')
    );
    controllerUserData = controllerUserData.replace(
      /ETCDCLUSTER/g,
      new Array(numberOfControllers)
        .fill(0)
        .map((_, i) => `https://10.240.0.1${i}:2379`)
        .join(',')
    );
    controllerUserData = controllerUserData.replace(/BUCKET_NAME/g, bucketName);
    // temporary solution for resolving node names
    controllerUserData = controllerUserData.replace(
      /CONTROLLER_NAMES/g,
      new Array(numberOfControllers)
        .fill(0)
        .map((_, i) => `10.240.0.1${i}  controller${i}`)
        .join('\n')
    );
    controllerUserData = controllerUserData.replace(
      /WORKER_NAMES/g,
      new Array(numberOfWorkers)
        .fill(0)
        .map((_, i) => `10.240.0.2${i} worker${i}`)
        .join('\n')
    );

    const controllers = [];
    for (let i = 0; i < numberOfControllers; i++) {
      const name = 'controller' + i;
      const localip = '10.240.0.1' + i;
      let userData = controllerUserData.slice();
      userData = userData.replace(/LOCALIP/g, localip);
      userData = userData.replace(/INSTANCE/g, name);
      controllers.push(
        new ec2.Instance(this, name, {
          instanceName: name,
          instanceType: controllerInstanceType,
          machineImage: machineImage,
          securityGroup: clusterSecurityGroup,
          privateIpAddress: localip,
          userData: ec2.UserData.custom(userData),
          vpcSubnets: { subnets: [vpc.publicSubnets[0]] },
          sourceDestCheck: true,
          keyName: keyName,
          role: kubeRole,
          vpc: vpc,
        })
      );
      apilb.node.addDependency(controllers[0]);
    }

    let workerUserData = readFileSync(
      path.join(__dirname, '../assets/workerUserData.sh'),
      'utf8'
    );
    workerUserData = workerUserData.replace(/APILBNAME/g, apilbName);
    // temporary solution for resolving node names
    workerUserData = workerUserData.replace(
      /CONTROLLER_NAMES/g,
      new Array(numberOfControllers)
        .fill(0)
        .map((_, i) => `10.240.0.1${i}  worker${i}`)
        .join('\n')
    );
    workerUserData = workerUserData.replace(
      /WORKER_NAMES/g,
      new Array(numberOfWorkers)
        .fill(0)
        .map((_, i) => `10.240.0.2${i} worker${i}`)
        .join('\n')
    );
    const workers = [];
    for (let i = 0; i < numberOfWorkers; i++) {
      const name = 'worker' + i;
      const localip = '10.240.0.2' + i;
      const podcidr = '10.200.' + i + '.0/24';
      let userData = workerUserData.slice();
      userData = userData.replace(/PODCIDR/g, podcidr);
      userData = userData.replace(/LOCALIP/g, localip);
      userData = userData.replace(/INSTANCE/g, name);
      workers.push(
        new ec2.Instance(this, name, {
          instanceName: name,
          instanceType: workerInstanceType,
          machineImage: machineImage,
          securityGroup: clusterSecurityGroup,
          privateIpAddress: localip,
          userData: ec2.UserData.custom(userData),
          vpcSubnets: { subnets: [vpc.publicSubnets[0]] },
          sourceDestCheck: true,
          keyName: keyName,
          role: kubeRole,
          vpc: vpc,
        })
      );
      new ec2.CfnRoute(this, name + 'PodRoute', {
        routeTableId: vpc.publicSubnets[0].routeTable.routeTableId,
        destinationCidrBlock: podcidr,
        instanceId: workers[0].instanceId,
      });
      apilb.node.addDependency(workers[0]);
    }
  }
}
