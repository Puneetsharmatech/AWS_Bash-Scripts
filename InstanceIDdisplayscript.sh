#!/bin/bash

# Variables - Replace these with your own values
AMI_ID="ami-0c614dee691cbbf37"         # Replace with your desired AMI ID
INSTANCE_TYPE="t2.micro"               # Instance type
SUBNET_ID="subnet-0441a3353fe994950"   # Your subnet ID
SECURITY_GROUP="sg-0f960f381a0dfe0c1"  # Your security group ID
KEY_NAME="SSMinstance"                 # Your existing key pair

# Define user data as a HEREDOC string
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

# Launch EC2 instance with inlined user data
INSTANCE_ID=$(aws ec2 run-instances \
    --image-id $AMI_ID \
    --instance-type $INSTANCE_TYPE \
    --subnet-id $SUBNET_ID \
    --security-group-ids $SECURITY_GROUP \
    --key-name $KEY_NAME \
    --associate-public-ip-address \
    --user-data "$USER_DATA" \
    --query "Instances[0].InstanceId" \
    --output text)

echo "EC2 Instance launched with ID: $INSTANCE_ID"

# Wait for the instance to be in running state
aws ec2 wait instance-running --instance-ids $INSTANCE_ID
echo "Instance $INSTANCE_ID is now running."

# Fetch the Public IP Address
PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids $INSTANCE_ID \
    --query "Reservations[0].Instances[0].PublicIpAddress" \
    --output text)

echo "Public IP: $PUBLIC_IP"
echo "Visit http://$PUBLIC_IP to check the Nginx server"
