variable "aws_region" { 
    type = string
    default = "us-east-1"
}

variable "aws_account_id" { 
    type = string 
}

variable "org_prefix" { 
    type = string
    default = "lead" 
}

variable "github_owner" { 
    type = string 
}

variable "github_repo" { 
    type = string 
}

variable "github_branch" { 
    type = string
    default = "main" 
}
