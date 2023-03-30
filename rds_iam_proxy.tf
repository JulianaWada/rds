provider "aws" {
  region = "us-east-1"
}
resource "aws_vpc" "vpc-proxy" {
  cidr_block = "10.0.0.0/16"
  
  enable_dns_hostnames = true
  enable_dns_support   = true

}
resource "aws_internet_gateway" "my_igw" {
  vpc_id = aws_vpc.vpc-proxy.id

  tags = {
    Name = "rds Internet Gateway"
  }
}

resource "aws_subnet" "subnet-proxy" {
  vpc_id            = aws_vpc.vpc-proxy.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-east-1a"
}

resource "aws_subnet" "subnet-proxy1" {
  vpc_id            = aws_vpc.vpc-proxy.id
  cidr_block        = "10.0.2.0/25"
  availability_zone = "us-east-1b"
}
resource "aws_db_subnet_group" "mysql-subnet-group" {
  name       = "mysql-subnet-group"
  subnet_ids = [aws_subnet.subnet-proxy.id, aws_subnet.subnet-proxy1.id]
}



resource "aws_db_instance" "mysql_instance" {
  #name              ="my_dbauthtest"
  allocated_storage      = 20
  engine                 = "mysql"
  engine_version         = "5.7"
  instance_class         = "db.t2.micro"
  username               = "admin"
  password               = "mypassword"
  db_name                = "mydatabase"
  parameter_group_name   = "default.mysql5.7"
  publicly_accessible    = true
  vpc_security_group_ids = [aws_security_group.mysql_sg.id]
  db_subnet_group_name   = aws_db_subnet_group.mysql-subnet-group.name
  skip_final_snapshot    = true

  tags = {
    Name = "MySQL RDS Instance"
  }
}



resource "aws_secretsmanager_secret" "mysql_proxy_secret3" {
  name = "my_mysql_proxy_secret3"
}

resource "aws_secretsmanager_secret_version" "mysql_proxy_secret_version2" {
  secret_id = aws_secretsmanager_secret.mysql_proxy_secret3.id
  secret_string = jsonencode({
    username = "admin"
    password = "mypassword"
  })
}

resource "aws_db_proxy" "mysql_proxy" {
  name                   = "my-mysql-proxy"
  engine_family          = "MYSQL"
  role_arn               = aws_iam_role.rds_proxy.arn
  vpc_security_group_ids = [aws_security_group.mysql_sg.id]
  vpc_subnet_ids         = [aws_subnet.subnet-proxy.id, aws_subnet.subnet-proxy1.id]

  auth {


    // SecretArn is required in UserAuthConfig
    auth_scheme = "SECRETS"
    secret_arn  = aws_secretsmanager_secret_version.mysql_proxy_secret_version2.arn
  }
}





resource "aws_iam_role" "rds_proxy" {
  name = "rds-proxy-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "rds.amazonaws.com"
        }
      }
    ]
  })
}


resource "aws_security_group" "mysql_sg" {
  vpc_id      = aws_vpc.vpc-proxy.id
  name_prefix = "mysql-sg-"
  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "lambda_sg" {
  vpc_id      = aws_vpc.vpc-proxy.id
  name_prefix = "lambda-sg-"
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}




data "archive_file" "zip_the_python_code" {
  type         = "zip"
  source_dir   = "${path.module}/python/"
  output_path = "${path.module}/python/iam_auth_secrets_proxy.zip"
}

resource "aws_lambda_function" "iam_auth_secrets_proxy" {
  function_name = "iam_auth_secrets_proxy"
  filename      = "${path.module}/python/iam_auth_secrets_proxy.zip"
  role          = aws_iam_role.lambda_role.arn
  handler       = "iam_auth_secrets_proxy.lambda_handler"
  runtime       = "python3.8"
  timeout       = 60
  memory_size   = 128
  environment {
    variables = {
      DB_HOST = aws_db_proxy.mysql_proxy.endpoint
      #DB_PORT = split(":", aws_db_proxy.mysql_proxy.endpoint)[4]
      DB_NAME     = aws_db_instance.mysql_instance.name
      DB_USER     = aws_db_instance.mysql_instance.username
      DB_PASSWORD = aws_db_instance.mysql_instance.password
    }
  }
  vpc_config {
    subnet_ids         = [aws_subnet.subnet-proxy.id, aws_subnet.subnet-proxy1.id]
    security_group_ids = [aws_security_group.lambda_sg.id]
  }
  depends_on = [
    aws_db_proxy.mysql_proxy,
    aws_iam_role.lambda_role,
    aws_db_instance.mysql_instance
  ]
}

resource "aws_iam_role" "lambda_role" {
  name = "lambda_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
     
    ]
     policy      = <<EOF
     {
    "Version": "2012-10-17",
    "Statement": [
     policy={
         {
    "Version": "2012-10-17",
     "Statement": [
         {
            "Sid": "VisualEditor0",
             "Effect": "Allow",
             "Action": [
                 "ec2:CreateNetworkInterface",
                 "ec2:DescribeNetworkInterfaces",
                 "ec2:DeleteNetworkInterface"
             ],
             "Resource": "*"
         },
         {
             "Sid": "VisualEditor1",
             "Effect": "Allow",
             "Action": "rds-db:connect",
             "Resource": "arn:aws:rds:us-east-1:439828058928:db-proxy:prx-025e6f14ed5cd66d9/budget_user"
        }
        

     }
  EOF
  })
}
resource "aws_iam_role_policy_attachment" "lambda_policy_attachment" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  role       = aws_iam_role.lambda_role.name
}

resource "aws_iam_role_policy_attachment" "lambda_role_attach" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
  role       = aws_iam_role.lambda_role.name
}

resource "aws_iam_role_policy_attachment" "proxies_policy_attachment" {
  policy_arn = "arn:aws:iam::aws:policy/AWSXrayWriteOnlyAccess"
  role       = aws_iam_role.lambda_role.name
}


