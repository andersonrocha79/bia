./build.sh
aws ecs update-service --cluster cluster-bia-01082025 --service service-bia-01082025  --force-new-deployment
