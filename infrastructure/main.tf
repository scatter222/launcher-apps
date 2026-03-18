terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

# --- Resource Group ---

resource "azurerm_resource_group" "main" {
  name     = var.instance_name
  location = var.location
}
