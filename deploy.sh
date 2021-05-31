#!/bin/bash
# TODO: Handle errors from API in a more robust way.

# TODO: Validate input

tfc_get() {
    curl --header "Authorization: Bearer $TOKEN" \
         --header "Content-Type: application/vnd.api+json" \
         --silent \
         https://app.terraform.io/api/v2$1
}

tfc_patch() {
    curl --header "Authorization: Bearer $TOKEN" \
         --header "Content-Type: application/vnd.api+json" \
         --silent \
         --data ${2:-""} \
         -X PATCH \
         https://app.terraform.io/api/v2$1
}

tfc_post() {
    curl --header "Authorization: Bearer $TOKEN" \
         --header "Content-Type: application/vnd.api+json" \
         --silent \
         --data ${2:-""} \
         -X POST \
         https://app.terraform.io/api/v2$1
}

workspace_data=$(tfc_get /workspaces/$WORKSPACE_ID | jq .data)

# Check workspace isnt locked. (fail if not in unlocked state)
locked=$(echo $workspace_data | jq .attributes.locked)
case $locked in
    true)
        echo $(echo $workspace_data | jq .attributes.name) is locked!
        exit 1
        ;;
    false)
        echo Workspace ready to be updated!
        ;;
    *)
        echo Could not get locked state from workspace!
        exit 1
        ;;
esac

# Update variable
cat > variable.update.json <<EOF
{
  "data": {
    "id":"$VARIABLE_ID",
    "attributes": {
      "key":"image",
      "value":"$IMAGE"
    },
    "type":"vars"
  }
}
EOF

var_data=$(tfc_patch /workspaces/$WORKSPACE_ID/vars/$VARIABLE_ID \
                     @variable.update.json | jq .data)
var_key=$(echo $var_data | jq -r .attributes.key)
var_value=$(echo $var_data | jq -r .attributes.value)
if [ "$var_value" != "$IMAGE" ]
then
    echo "Failed to update variable: {\"$var_key\": \"$var_value\"}"
    exit 1
fi
echo "Variable has been updated: {\"$var_key\": \"$var_value\"}"

# Queue plan
cat > queue.run.json <<EOF
{
  "data": {
    "attributes": {
      "is-destroy": false,
      "message": "GitHub Actions is deploying new version $IMAGE"
    },
    "type":"runs",
    "relationships": {
      "workspace": {
        "data": {
          "type": "workspaces",
          "id": "$WORKSPACE_ID"
        }
      }
    }
  }
}
EOF

run_data=$(tfc_post /runs @queue.run.json | jq .data)
run_id=$(echo $run_data | jq -r .id)
if [ -z "$run_id" ] || [ "$run_id" == "null" ]
then
    echo "Failed to queue run"
    exit 1
fi
echo "Created run: $run_id"

run_status=$(echo $run_data | jq -r .attributes.status)
while true
do
    echo "Waiting for plan to be ready ($run_status)"

    case $run_status in
        pending | plan_queued | planning)
            ;;
        planned)
            echo "Run has finished planning, ready to be applied."
            break;
            ;;
        *)
            echo "Run failed with status: ($run_status)"
            exit 1
            ;;
    esac

    sleep 10
    run_data=$(tfc_get /runs/$run_id | jq -r .data)
    run_status=$(echo $run_data | jq -r .attributes.status)
done

if [ "$run_status" != "planned" ]
then
    echo "Failed to plan change, check workspace."
    exit 1
fi

# Apply plan
cat > apply.run.json <<EOF
{
  "comment": "Automatic confirm via GitHub action step!"
}
EOF

# hide result of curl
run_apply=$(tfc_post /runs/$run_id/actions/apply @apply.run.json)
run_data=$(tfc_get /runs/$run_id | jq -r .data)
run_status=$(echo $run_data | jq -r .attributes.status)
while true
do
    echo "Applying run: ($run_status)"

    case $run_status in
        applied | planned_and_finished)
            echo "Run has been applied, IaC is up to date."
            exit 0
            ;;
        errored)
            echo "Failed to run approved plan."
            exit 1
            ;;
        *)
            ;;
    esac

    sleep 10
    run_data=$(tfc_get /runs/$run_id | jq -r .data)
    run_status=$(echo $run_data | jq -r .attributes.status)
done

echo "Failed to apply change, check workspace."
exit 1
