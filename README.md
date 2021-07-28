# Welcome to Kubernetes The Hard Way with AWS CDK:

This project is based on the Cloud Development Kit (CDK) by AWS and helps you provision a [Kubernetes](https://kubernetes.io/) cluster on [Amazon Web Services](https://aws.amazon.com/) based on few parameters.

While building this project, I frequently referred to [Kelsey Hightower's guide](https://github.com/kelseyhightower/kubernetes-the-hard-way).

## How to run

In order to build and run the project, you need an active AWS account with administrator access. After cloning the project:

- Use `npm install` in the project directory to install dependencies
- Install the CDK tool using `npm install -g cdk`
- Build the project code with `npm run build`

Now you are ready to provision your cluster, but before, you need to export these parameter as environment variables (this is Linux/MacOS syntax):

- `export WORKER_COUNT=1` the number of worker nodes
- `export CONTROLLER_COUNT=1` the number of controller nodes
- `export KEY_NAME=mykey` the name of the SSH key used to connect to the instances
- `export BUCKET_NAME=mybucket` the S3 bucket where you need to store your SSH key and the file `assets/coredns.yaml` before you deploy

To deploy the cluster use `cdk deploy`inside the project directory.

## Progress

- Currently, the cluster is provisioned using t2.micro instances (to save cost), this will be parameterized soon.
- The is no easy method to customize the various IP ranges assigned to the cluster for now.
- Once the cluster is running, you will need to generate your own `kubectl` context config.
