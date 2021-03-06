#!/bin/bash
set -e

# $JENKINS_VERSION should be an LTS release
JENKINS_VERSION="1.642.3"

# List of Jenkins plugins, in the format "${PLUGIN_NAME}/${PLUGIN_VERSION}"
JENKINS_PLUGINS=(
    "conditional-buildstep/1.3.3"
    "credentials/1.25"
    "email-ext/2.41.3"
    "envinject/1.92.1"
    "git/2.4.3"
    "git-client/1.19.6"
    "greenballs/1.15"
    "hipchat/1.0.0"
    "jenkins-multijob-plugin/1.20"
    "job-dsl/1.44"
    "junit/1.11"
    "mesos/0.11.0"
    "metadata/1.1.0b"
    "monitoring/1.59.0"
    "parameterized-trigger/2.30"
    "postbuild-task/1.8"
    "rebuild/1.25"
    "run-condition/1.0"
    "saferestart/0.3"
    "scm-api/1.1"
    "script-security/1.17"
    "slack/2.0.1"
    "ssh-credentials/1.11"
    "token-macro/1.12.1"
    "workflow-step-api/1.11"
)

JENKINS_WAR_MIRROR="http://mirrors.jenkins-ci.org/war-stable"
JENKINS_PLUGINS_MIRROR="http://mirrors.jenkins-ci.org/plugins"

usage () {
    cat <<EOT
Usage: $0 <required_arguments> [optional_arguments]

REQUIRED ARGUMENTS
  -z, --zookeeper     The ZooKeeper URL, e.g. zk://10.132.188.212:2181/mesos

OPTIONAL ARGUMENTS
  -u, --user          The user to run the Jenkins slave under. Defaults to
                      the same username that launched the Jenkins master.
  -d, --docker        The name of a Docker image to use for the Jenkins slave.

EOT
    exit 1
}

# Ensure we have an accessible wget
if ! command -v wget > /dev/null; then
    echo "Error: wget not found in \$PATH"
    echo
    exit 1
fi

# # Print usage if arguments passed is less than the required number
if [[ ! $# > 1 ]]; then
    usage
fi

# Process command line arguments
while [[ $# > 1 ]]; do
    key="$1"; shift
    case $key in
        -z|--zookeeper)
            ZOOKEEPER_PATHS="$1"   ; shift ;;
        -u|--user)
            SLAVE_USER="${1-''}"   ; shift ;;
        -d|--docker)
            DOCKER_IMAGE="${1-''}" ; shift ;;
        -h|--help)
            usage ;;
        *)
            echo "Unknown option: ${key}"; exit 1 ;;
    esac
done

# Jenkins WAR file
if [[ ! -f "jenkins.war" ]]; then
    wget -nc "${JENKINS_WAR_MIRROR}/${JENKINS_VERSION}/jenkins.war"
fi

# Jenkins plugins
[[ ! -d "plugins" ]] && mkdir "plugins"
for plugin in ${JENKINS_PLUGINS[@]}; do
    IFS='/' read -a plugin_info <<< "${plugin}"
    plugin_path="${plugin_info[0]}/${plugin_info[1]}/${plugin_info[0]}.hpi"
    wget -nc -P plugins "${JENKINS_PLUGINS_MIRROR}/${plugin_path}"
done

# Jenkins config files
PORT=${PORT-"8080"}

sed -i "s!_MAGIC_ZOOKEEPER_PATHS!${ZOOKEEPER_PATHS}!" config.xml
sed -i "s!_MAGIC_JENKINS_URL!http://${HOST}:${PORT}!" jenkins.model.JenkinsLocationConfiguration.xml
sed -i "s!_MAGIC_JENKINS_SLAVE_USER!${SLAVE_USER}!" config.xml
sed -i "s!_MAGIC_SLACK_DOMAIN!${SLACK_DOMAIN}!" jenkins.plugins.slack.SlackNotifier.xml
sed -i "s!_MAGIC_SLACK_TOKEN!${SLACK_TOKEN}!" jenkins.plugins.slack.SlackNotifier.xml
sed -i "s!_MAGIC_SLACK_ROOM!${SLACK_ROOM}!" jenkins.plugins.slack.SlackNotifier.xml
sed -i "s!_MAGIC_BUILDSERVER_URL!${BUILDSERVER_URL}!" jenkins.plugins.slack.SlackNotifier.xml

# Optional: configure containerInfo
if [[ ! -z $DOCKER_IMAGE ]]; then
    container_info="<containerInfo>\n            <type>DOCKER</type>\n            <dockerImage>${DOCKER_IMAGE}</dockerImage>\n            <networking>BRIDGE</networking>\n            <useCustomDockerCommandShell>false</useCustomDockerCommandShell>\n            <dockerPrivilegedMode>false</dockerPrivilegedMode>\n             <dockerForcePullImage>false</dockerForcePullImage>\n          </containerInfo>"

    sed -i "s!_MAGIC_CONTAINER_INFO!${container_info}!" config.xml
else
    # Remove containerInfo from config.xml
    sed -i "/_MAGIC_CONTAINER_INFO/d" config.xml
fi

# Register service with Consul
curl \
    -X PUT \
    -H "Content-Type: application/json" \
    -d@- \
    "http://localhost:8500/v1/agent/service/register" <<EOF
{
  "ID": "jenkins-master",
  "Name": "jenkins",
  "Tags": [
    "internal-http"
  ],
  "Port": $PORT,
  "Check": {
    "HTTP": "http://localhost:$PORT",
    "Interval": "10s"
  }
}
EOF

# Start the master
export JENKINS_HOME="$(pwd)"
java \
    -Dhudson.DNSMultiCast.disabled=true            \
    -Dhudson.udp=-1                                \
    -jar jenkins.war                               \
    -Djava.awt.headless=true                       \
    --webroot=war                                  \
    --httpPort=${PORT}                             \
    --ajp13Port=-1                                 \
    --httpListenAddress=0.0.0.0                    \
    --ajp13ListenAddress=127.0.0.1                 \
    --preferredClassLoader=java.net.URLClassLoader \
    --logfile=../jenkins.log
