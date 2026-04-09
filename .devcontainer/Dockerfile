FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

# Install SSH server and essential tools
RUN apt-get update && apt-get install -y \
    curl wget git htop build-essential \
    openssh-server \
    && rm -rf /var/lib/apt/lists/*
