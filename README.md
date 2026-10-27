# Blue-Green Deployment with Docker and NGINX

A hands-on deployment automation project demonstrating blue-green releases, health checks, NGINX traffic switching, rollback, and weighted canary routing.

## Objectives

- Run separate Blue and Green application containers.
- Use NGINX as the single public HTTP entry point.
- Validate application health before deployment cutover.
- Switch traffic by updating and reloading NGINX configuration.
- Roll back to the previous environment.
- Configure weighted canary traffic.
- Persist deployment state and capture test evidence.

## Architecture

```text
                  Client :80
                      |
                      v
                +-----------+
                |   NGINX   |
                +-----------+
                      |
               blue-green-net
                  /       \
                 v         v
          +----------+ +----------+
          | Blue App | | Green App|
          |  :3000   | |  :3000   |
          +----------+ +----------+


Only NGINX publishes a host port. The application containers communicate over the Docker bridge network blue-green-net.


Technology Stack

- Docker Engine
- NGINX
- Python HTTP server
- Bash
- Docker health checks
- curl and jq

Project Structure

app/                 Python application and Dockerfile
nginx/conf.d/        Active NGINX routing configuration
scripts/pipeline.sh Deployment, rollback, status, and canary commands
state/               Local deployment state
evidence/             Validation output
README.md             Project documentation
.gitignore            Files excluded from Git


Prerequisites

- Linux host with Docker Engine
- Bash and curl
- jq for the traffic distribution test
- Permission to run Docker commands

On the lab EC2 host, Docker commands use sudo.

Pipeline Usage

Run from the project directory:
./scripts/pipeline.sh status
./scripts/pipeline.sh deploy
./scripts/pipeline.sh rollback
./scripts/pipeline.sh canary 30


- status: shows the active environment, standby environment, container health, and active health endpoint.
- deploy: builds the application image, updates the standby environment, checks health, and switches NGINX traffic.
- rollback: restores the previous environment after a deployment, or removes canary routing and returns traffic to the current active environment.
- canary 30: configures approximately 30% of traffic for the standby environment and 70% for the active environment.

Canary percentages must be between 1 and 99. Weighted balancing is approximate over small request samples.

Application Endpoints

curl -sS http://localhost/
curl -sS http://localhost/health


The root endpoint returns environment and version information. The health endpoint reports application health.

Check container health:

sudo docker ps --filter name=blue-app --filter name=green-app


Check NGINX configuration and reload it without restarting the container:

sudo docker exec nginx-router nginx -t
sudo docker exec nginx-router nginx -s reload


Validation Results

Tests performed during this lab:
1. Switched NGINX traffic between Blue and Green.
2. Deployed a new Blue version and confirmed the container became healthy.
3. Rolled back to Green and verified healthy traffic.
4. Configured a 30% Blue canary. A previous 30-request sample produced 9 Blue responses and 21 Green responses.
5. Stopped Blue, observed failed requests, and manually ran rollback to restore Green traffic.
6. Restarted Blue and confirmed both application containers were healthy.
7. Used SIMULATE_POST_SWITCH_FAILURE=1 to exercise the pipeline's post-switch failure handler. It restored Green and verified the route.
8. Captured final container, routing, health, and NGINX restart information in evidence/final-validation.txt.

Testing distinction: the automatic rollback handler was tested using its deliberate failure-simulation hook. Recovery after stopping Blue was performed with the manual rollback command; automatic recovery from a real container crash was not demonstrated.

Evidence
See evidence/final-validation.txt for the captured final state. The file represents a snapshot from the time it was recorded; run the status and health commands again for current state.

Limitations
- This is a single-host lab, not a highly available production platform.
- Canary weights do not guarantee an exact percentage in every small sample.
- Health checks run during deployment; continuous monitoring and automatic recovery from every later failure are not implemented.
- Deployment state is stored locally on the host.

Learning Outcomes
- Blue-green deployment concepts
- Docker networks and health checks
- NGINX reverse proxy configuration
- Bash deployment automation
- Canary traffic weighting
- Rollback and failure testing
- Evidence-based technical documentation

Lab Environment
Ubuntu EC2 lab, 27 October 2026.

cat > .gitignore
