terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Get default VPC and subnets (simple setup, not super "enterprise" but OK for lab)
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Security Group for Load Balancer (public HTTP)
resource "aws_security_group" "alb_sg" {
  name        = "hello-docker-alb-sg"
  description = "Allow HTTP from the internet"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "hello-docker-alb-sg"
  }
}

# Security Group for EC2 instances (only traffic from ALB)
resource "aws_security_group" "ec2_sg" {
  name        = "hello-docker-ec2-sg"
  description = "Allow HTTP traffic from ALB only"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP from ALB"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    security_groups = [
      aws_security_group.alb_sg.id
    ]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "hello-docker-ec2-sg"
  }
}

# Get Amazon Linux 2 AMI
data "aws_ami" "amazon_linux_2" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Launch Template for ASG
resource "aws_launch_template" "app" {
  name_prefix   = "hello-docker-lt-"
  image_id      = data.aws_ami.amazon_linux_2.id
  instance_type = var.instance_type

  vpc_security_group_ids = [aws_security_group.ec2_sg.id]

  user_data = base64encode(
    templatefile("${path.module}/userdata.sh", {
      docker_image = var.docker_image
    })
  )

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "hello-docker-instance"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Target Group for ALB
resource "aws_lb_target_group" "app" {
  name     = "hello-docker-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  target_type = "instance"

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200-399"
    interval            = 30
    unhealthy_threshold = 2
    healthy_threshold   = 2
    timeout             = 5
  }

  tags = {
    Name = "hello-docker-tg"
  }
}

# Application Load Balancer
resource "aws_lb" "app" {
  name               = "hello-docker-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = data.aws_subnets.default.ids

  idle_timeout = 60

  tags = {
    Name = "hello-docker-alb"
  }
}

# Listener HTTP 80
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# Auto Scaling Group
resource "aws_autoscaling_group" "app" {
  name                      = "hello-docker-asg"
  max_size                  = 7
  min_size                  = 2
  desired_capacity          = 2
  vpc_zone_identifier       = data.aws_subnets.default.ids
  health_check_type         = "EC2"
  health_check_grace_period = 120

  target_group_arns = [aws_lb_target_group.app.arn]

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "hello-docker-asg-instance"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

#############################
# SCALING POLICIES
#############################

# 1 CPU-based Target Tracking Policy
resource "aws_autoscaling_policy" "cpu_policy" {
  name                   = "hello-docker-cpu-target-tracking"
  policy_type            = "TargetTrackingScaling"
  autoscaling_group_name = aws_autoscaling_group.app.name

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }

    # Target CPU utilization (e.g. 50%)
    target_value = 50
  }
}

# 2 Memory-based Target Tracking Policy (custom metric from CloudWatch Agent)
resource "aws_autoscaling_policy" "memory_policy" {
  name                   = "hello-docker-memory-target-tracking"
  policy_type            = "TargetTrackingScaling"
  autoscaling_group_name = aws_autoscaling_group.app.name

  target_tracking_configuration {
    customized_metric_specification {
      namespace   = "CWAgent"
      metric_name = "mem_used_percent"
      statistic   = "Average"
      unit        = "Percent"

      # Use metric_dimension blocks, NOT dimensions
      metric_dimension {
        name  = "AutoScalingGroupName"
        value = aws_autoscaling_group.app.name
      }
    }

    target_value     = 70
    disable_scale_in = false
  }
}
