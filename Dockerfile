FROM debian:jessie-slim
LABEL maintainer="aaron@roydhouse.com"

ENV KUBE_LATEST_VERSION="v1.5.2"
RUN export DEBIAN_FRONTEND=noninteractive \
  && apt-get update -y \
  && apt-get install -y apt-utils gettext-base python curl unzip \
  && curl -sS -L https://s3.amazonaws.com/aws-cli/awscli-bundle.zip -o awscli-bundle.zip \
  && unzip awscli-bundle.zip \
  && ./awscli-bundle/install -i /usr/local/aws -b /usr/local/bin/aws \
  && rm -rf ./awscli-bundle \
  && curl -sS -L https://storage.googleapis.com/kubernetes-release/release/${KUBE_LATEST_VERSION}/bin/linux/amd64/kubectl -o /usr/local/bin/kubectl \
  && chmod +x /usr/local/bin/kubectl \
  && apt-get autoremove -y \
  && apt-get clean -y

# We will start and expose ssh on port 22
EXPOSE 22

# Add the container start script, which will start ssh
COPY bin/ /root/bin
ENTRYPOINT ["/root/bin/kube-backup.sh"]
