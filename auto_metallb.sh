#!/bin/bash

# Function to install MetalLB in a selected kubeconfig context
install_metallb() {
  CONTEXT=$1
  
  echo "Switching to context: $CONTEXT"
  kubectl config use-context $CONTEXT

  # Step 1: Get the Docker network used by this Kind cluster
  echo "Retrieving Docker network for the Kind cluster ($CONTEXT)..."
  # Get the Docker container ID of the Kind control plane node
  cutName=$(echo $CONTEXT | sed 's/kind-//g')
  CONTAINER_ID=$(docker ps --filter "name=$cutName-control-plane" --format "{{.ID}}")
  
  if [ -z "$CONTAINER_ID" ]; then
    echo "Error: Could not find Docker container for Kind cluster context: $CONTEXT"
    return
  fi
  
  # Get the network name used by this Kind cluster
  NETWORK_NAME=$(docker inspect "$CONTAINER_ID" --format '{{json .NetworkSettings.Networks}}' | jq -r 'keys[]')
  
  if [ -z "$NETWORK_NAME" ]; then
    echo "Error: Could not find Docker network for container ID: $CONTAINER_ID"
    return
  fi

  # Step 2: Get the subnet for the Docker network
  SUBNET_CIDR=$(docker network inspect "$NETWORK_NAME" --format '{{(index .IPAM.Config 0).Subnet}}')
  
  if [ -z "$SUBNET_CIDR" ]; then
    echo "Error: Could not retrieve subnet CIDR for network: $NETWORK_NAME"
    return
  fi

  # Step 3: Generate an IP range for MetalLB based on the Docker subnet
  echo "Using Docker network subnet: $SUBNET_CIDR"
  
  # Assuming the subnet is something like 172.18.0.0/16, we can reserve the last part of this range for MetalLB
  IFS='/' read -r subnet_base subnet_mask <<< "$SUBNET_CIDR"
  IFS='.' read -r oct1 oct2 oct3 oct4 <<< "$subnet_base"
  
  # Assign MetalLB a range in the last portion of this subnet (e.g., 172.18.255.1 - 172.18.255.250)
  METALLB_RANGE="$oct1.$oct2.255.1-$oct1.$oct2.255.250"
  
  echo "MetalLB IP address pool will use the range: $METALLB_RANGE"

  # Step 4: Install MetalLB components
  echo "Installing MetalLB on context: $CONTEXT"
  kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.7/config/manifests/metallb-native.yaml

  # Step 5: Wait for MetalLB pods to be ready
  echo "Waiting for MetalLB pods to be ready..."
  kubectl wait --namespace metallb-system --for=condition=ready pod --selector=app=metallb --timeout=90s

  # Step 6: Create a MetalLB IP address pool configuration
  echo "Creating MetalLB configuration for context: $CONTEXT"
  cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: metallb-ip-pool
  namespace: metallb-system
spec:
  addresses:
  - $METALLB_RANGE
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: advert
  namespace: metallb-system
spec:
  ipAddressPools:
  - metallb-ip-pool
EOF

  echo "MetalLB setup completed for context: $CONTEXT"
}

# Step 7: Display available contexts and allow user to select clusters
available_contexts=$(kubectl config get-contexts -o name)

echo "Available kubeconfig contexts:"
select context in $available_contexts "Exit"; do
  case $context in
    Exit)
      echo "Exiting script."
      break
      ;;
    *)
      echo "You selected: $context"
      install_metallb $context
      ;;
  esac
done
