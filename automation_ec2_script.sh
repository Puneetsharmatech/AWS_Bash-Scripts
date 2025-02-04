#!/bin/bash

# Set variables
VPC_NAME="MyVPC"
VPC_CIDR="10.0.0.0/16"
SUBNET1_CIDR="10.0.1.0/24"
SUBNET2_CIDR="10.0.2.0/24"
REGION="us-east-1"
AMI_ID="ami-0c614dee691cbbf37"  # Change to a valid AMI ID
INSTANCE_TYPE="t2.micro"
KEY_NAME="SSMinstance"  # Change to your key pair name
SG_NAME="automationSecurity_group"
TG_NAME="MyTargetGroup"
LB_NAME="MyLoadBalancer"

USER_DATA=$(cat <<'EOF'
#!/bin/bash
set -ex  # Enable debugging and exit on error

# Update and install Nginx
yum update -y
yum install -y nginx

# Fetch instance metadata
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/instance-id)

# Create index.html with instance ID
cat << HTML > /usr/share/nginx/html/index.html
<html>
<head>
  <title>Instance ID</title>
</head>
<body>
  <h1>Instance ID: $INSTANCE_ID</h1>
</body>
</html>
HTML

# Configure Nginx
cat << CONF > /etc/nginx/conf.d/default.conf
server {
    listen 80;
    server_name _;

    root /usr/share/nginx/html;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
CONF

# Restart Nginx service
systemctl enable nginx
systemctl restart nginx
EOF
)








# Create VPC
echo "Creating VPC..."
VPC_ID=$(aws ec2 create-vpc --cidr-block $VPC_CIDR --query 'Vpc.VpcId' --output text)
aws ec2 create-tags --resources $VPC_ID --tags Key=Name,Value=$VPC_NAME

# Create Subnets
echo "Creating Subnets..."
SUBNET1_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $SUBNET1_CIDR --availability-zone ${REGION}a --query 'Subnet.SubnetId' --output text)
SUBNET2_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $SUBNET2_CIDR --availability-zone ${REGION}b --query 'Subnet.SubnetId' --output text)

# Create Internet Gateway and attach to VPC
echo "Creating and attaching Internet Gateway..."
IGW_ID=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID

# Create Route Table and route to IGW
echo "Setting up Route Table..."
RT_ID=$(aws ec2 create-route-table --vpc-id $VPC_ID --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id $RT_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
aws ec2 associate-route-table --route-table-id $RT_ID --subnet-id $SUBNET1_ID
aws ec2 associate-route-table --route-table-id $RT_ID --subnet-id $SUBNET2_ID

# Create Security Group
echo "Creating Security Group..."
SG_ID=$(aws ec2 create-security-group --group-name $SG_NAME --description "Allow HTTP and SSH" --vpc-id $VPC_ID --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 22 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 80 --cidr 0.0.0.0/0

# Launch EC2 Instances
echo "Launching EC2 Instances..."
INSTANCE1_ID=$(aws ec2 run-instances \
     --image-id $AMI_ID \
     --instance-type $INSTANCE_TYPE \
     --key-name $KEY_NAME \
     --subnet-id $SUBNET1_ID \
     --security-group-ids $SG_ID \
     --associate-public-ip-address \
     --user-data "$USER_DATA" \
     --query 'Instances[0].InstanceId' \
     --output text)


INSTANCE2_ID=$(aws ec2 run-instances \
    --image-id $AMI_ID \
    --instance-type $INSTANCE_TYPE \
    --key-name $KEY_NAME \
    --subnet-id $SUBNET2_ID \
    --associate-public-ip-address \
    --security-group-ids $SG_ID \
    --user-data "$USER_DATA" \
    --query 'Instances[0].InstanceId' \
    --output text)

# Wait for instances to be running
echo "Waiting for instances to be in running state..."
aws ec2 wait instance-running --instance-ids $INSTANCE1_ID $INSTANCE2_ID

# Get instance private IPs
INSTANCE1_IP=$(aws ec2 describe-instances \
    --instance-ids $INSTANCE1_ID \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' \
    --output text)
INSTANCE2_IP=$(aws ec2 describe-instances --instance-ids $INSTANCE2_ID --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)

# Install web server on instances
#echo "Installing web server..."


#aws ec2 associate-address --instance-id $INSTANCE1_ID
#aws ec2 associate-address --instance-id $INSTANCE2_ID

# Create Load Balancer Target Group
echo "Creating Target Group..."
TG_ARN=$(aws elbv2 create-target-group --name $TG_NAME --protocol HTTP --port 80 --vpc-id $VPC_ID --target-type instance --query 'TargetGroups[0].TargetGroupArn' --output text)

# Register Instances with Target Group
echo "Registering instances with Target Group..."
aws elbv2 register-targets --target-group-arn $TG_ARN --targets Id=$INSTANCE1_ID Id=$INSTANCE2_ID

# Create Load Balancer
echo "Creating Load Balancer..."
LB_ARN=$(aws elbv2 create-load-balancer --name $LB_NAME --subnets $SUBNET1_ID $SUBNET2_ID --security-groups $SG_ID --scheme internet-facing --type application --query 'LoadBalancers[0].LoadBalancerArn' --output text)

# Create Listener
echo "Creating Listener..."
aws elbv2 create-listener --load-balancer-arn $LB_ARN --protocol HTTP --port 80 --default-actions Type=forward,TargetGroupArn=$TG_ARN

# Get Load Balancer URL
LB_DNS=$(aws elbv2 describe-load-balancers --query "LoadBalancers[?LoadBalancerArn=='$LB_ARN'].DNSName" --output text)

echo "Load Balancer setup completed. Access your application at: http://$LB_DNS"
