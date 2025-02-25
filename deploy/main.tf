locals {
  app_name = "test-deploy"
  aws_region = "us-east-1"
}


provider "aws" {
  region = local.aws_region
  profile = "myaws"
}

data "aws_ami" "ubuntu_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

data "aws_vpc" "default" {
  default = true
}


resource "aws_eip" "eip" {
 domain = "vpc"
}
resource "aws_eip_association" "eip_assoc" {
 instance_id   = aws_instance.app_instance.id
 allocation_id = aws_eip.eip.id
}

data "aws_subnet" "default_subnet" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }

  filter {
    name   = "availability-zone"
    values = ["${local.aws_region}a"]
  }
}

resource "aws_security_group" "instance_sg" {
  name   = "${local.app_name}-instance-sg"
  vpc_id = data.aws_vpc.default.id

  ingress {
    description = "Allow HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow Docker registry"
    from_port   = 5000
    to_port     = 5000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # SSH
  ingress {
    description = "Allow SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_key_pair" "app_deployer" {
  key_name   = "terraform-deploy_${local.app_name}-key"
  public_key = file("./.keys/id_rsa.pub") # Path to your public SSH key
}

resource "aws_instance" "app_instance" {
  ami                    = data.aws_ami.ubuntu_linux.id
  instance_type          = "t3a.small"  # just change it to another type if you need, check https://instances.vantage.sh/
  subnet_id              = data.aws_subnet.default_subnet.id
  vpc_security_group_ids = [aws_security_group.instance_sg.id]
  key_name               = aws_key_pair.app_deployer.key_name

  # prevent accidental termination of ec2 instance and data loss
  # if you will need to recreate the instance still (not sure why it can be?), you will need to remove this block manually by next command:
  # > terraform taint aws_instance.app_instance
  lifecycle {
    prevent_destroy = true
    ignore_changes = [ami]
  }

  root_block_device {
    volume_size = 20 // Size in GB for root partition
    volume_type = "gp2"
    
    # Even if the instance is terminated, the volume will not be deleted, delete it manually if needed
    delete_on_termination = false
  }

  user_data = <<-EOF
    #!/bin/bash
    sudo apt-get update
    sudo apt-get install ca-certificates curl
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    # Add the repository to Apt sources:
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update

    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin screen

    systemctl start docker
    systemctl enable docker
    usermod -a -G docker ubuntu
  EOF

  tags = {
    Name = "${local.app_name}-instance"
  }
}

resource "null_resource" "setup_registry" {
  provisioner "local-exec" {
    command = <<-EOF
      echo "Generating secret for local registry"
      sha256sum ./.keys/id_rsa | cut -d ' ' -f1 | tr -d '\n' > ./.keys/registry.pure

      echo "Creating htpasswd file for local registry"
      docker run --rm --entrypoint htpasswd httpd:2 -Bbn ci-user $(cat ./.keys/registry.pure) > ./.keys/registry.htpasswd

      echo "Generating server certificate for registry"
      openssl genrsa -out ./.keys/registry.key 4096
      echo "subjectAltName=DNS:appserver.local,DNS:localhost,IP:127.0.0.1" > san.ext
      openssl req -new -key ./.keys/registry.key -subj "/CN=appserver.local" -addext "$(cat san.ext)" -out ./.keys/registry.csr

      openssl x509 -req -days 365 -CA ./.keys/ca.pem -CAkey ./.keys/ca.key -set_serial 01 -in ./.keys/registry.csr -extfile san.ext -out ./.keys/registry.crt 

      echo "Copying registry secret files to the instance"
      rsync -t -avz -e "ssh -i ./.keys/id_rsa -o StrictHostKeyChecking=no" \
        ./.keys/registry.* ubuntu@${aws_eip_association.eip_assoc.public_ip}:/home/ubuntu/registry-auth
    EOF
  }

  provisioner "remote-exec" {
    inline = [<<-EOF
      # wait for docker to be installed and started
      bash -c 'while ! command -v docker &> /dev/null; do echo \"Waiting for Docker to be installed...\"; sleep 1; done'
      bash -c 'while ! docker info &> /dev/null; do echo \"Waiting for Docker to start...\"; sleep 1; done'

      # remove old registry if exists
      docker rm -f registry
      # run new registry
      docker run -d --network host \
        --name registry \
        --restart always \
        -v /home/ubuntu/registry-data:/var/lib/registry \
        -v /home/ubuntu/registry-auth:/auth\
        -e "REGISTRY_AUTH=htpasswd" \
        -e "REGISTRY_AUTH_HTPASSWD_REALM=Registry Realm" \
        -e "REGISTRY_AUTH_HTPASSWD_PATH=/auth/registry.htpasswd" \
        -e "REGISTRY_HTTP_TLS_CERTIFICATE=/auth/registry.crt" \
        -e "REGISTRY_HTTP_TLS_KEY=/auth/registry.key" \
        registry:2

      EOF
    ]

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = file("./.keys/id_rsa")
      host        = aws_eip_association.eip_assoc.public_ip
    }
  }

  triggers = {
    always_run = 1 # change number to redeploy registry (if for some reason it was removed)
  }
}


resource "null_resource" "sync_files_and_run" {

  provisioner "local-exec" {
    command = <<-EOF

      # map appserver.local to the instance (in GA we don't know the IP, so have to use this mapping)
      grep -q "appserver.local" /etc/hosts || echo "${aws_eip_association.eip_assoc.public_ip} appserver.local" | sudo tee -a /etc/hosts

      # hosts modification may take some time to apply
      sleep 5

      # generate buildx authorization
      sha256sum ./.keys/id_rsa | cut -d ' ' -f1 | tr -d '\n' > ./.keys/registry.pure
      echo '{"auths":{"appserver.local:5000":{"auth":"'$(echo -n "ci-user:$(cat ./.keys/registry.pure)" | base64 -w 0)'"}}}' > ~/.docker/config.json

      echo "Running build"
      docker buildx bake --progress=plain --push --allow=fs.read=..

      # compose temporarily it is not working https://github.com/docker/compose/issues/11072#issuecomment-1848974315
      # docker compose --progress=plain -p app -f ./compose.yml build --push

      # if you will change host, pleasee add -o StrictHostKeyChecking=no
      echo "Copy files to the instance" 
      rsync -t -avz --mkpath -e "ssh -i ./.keys/id_rsa -o StrictHostKeyChecking=no" \
        --delete \
        --exclude '.terraform' \
        --exclude '.keys' \
        --exclude 'tfplan' \
        . ubuntu@${aws_eip_association.eip_assoc.public_ip}:/home/ubuntu/${local.app_name}/deploy/

      EOF
  }

  # Run docker compose after files have been copied
  provisioner "remote-exec" {
    inline = [<<-EOF
      # wait for docker to be installed and started
      bash -c 'while ! command -v docker &> /dev/null; do echo \"Waiting for Docker to be installed...\"; sleep 1; done'
      bash -c 'while ! docker info &> /dev/null; do echo \"Waiting for Docker to start...\"; sleep 1; done'
      
      cat /home/ubuntu/registry-auth/registry.pure | docker login localhost:5000 -u ci-user --password-stdin
        
      cd /home/ubuntu/${local.app_name}/deploy

      echo "Spinning up the app"
      docker compose --progress=plain -p app -f compose.yml up -d --remove-orphans

      # cleanup unused cache (run in background to not block terraform)
      screen -dm docker system prune -f
      screen -dm docker exec registry registry garbage-collect /etc/docker/registry/config.yml --delete-untagged=true 
    EOF
    ]

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = file("./.keys/id_rsa")
      host        = aws_eip_association.eip_assoc.public_ip
    }
  
  }

  # Ensure the resource is triggered every time based on timestamp or file hash
  triggers = {
    always_run = timestamp()
  }

  depends_on = [aws_instance.app_instance, aws_eip_association.eip_assoc, null_resource.setup_registry]
}


output "instance_public_ip" {
  value = aws_eip_association.eip_assoc.public_ip
}


######### META, tf state ##############


# S3 bucket for storing Terraform state
resource "aws_s3_bucket" "terraform_state" {
  bucket = "${local.app_name}-terraform-state"
}

resource "aws_s3_bucket_lifecycle_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.bucket

  rule {
    status = "Enabled"
    id = "Keep only the latest version of the state file"

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.bucket

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.bucket

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "AES256"
    }
  }
}


# Configure the backend to use the S3 bucket
terraform {
 backend "s3" {
   bucket         = "test-deploy-terraform-state"
   key            = "state.tfstate"  # Define a specific path for the state file
   region         = "us-east-1"
   profile        = "myaws"
   use_lockfile   = true
 }
}