#!/bin/bash
# Copyright (C) 2024 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

set -x

IMAGE_REPO=${IMAGE_REPO:-"opea"}
export REGISTRY=${IMAGE_REPO}
export TAG="comps"
echo "REGISTRY=IMAGE_REPO=${IMAGE_REPO}"
echo "TAG=${TAG}"

WORKPATH=$(dirname "$PWD")
host_ip=$(hostname -I | awk '{print $1}')
LOG_PATH="$WORKPATH/tests"
export service_name="textgen-native-phi4-multimodal-gaudi"

function build_docker_images() {
    cd $WORKPATH
    docker build --no-cache -t ${REGISTRY:-opea}/llm-textgen-phi4-gaudi:${TAG:-latest} --build-arg https_proxy=$https_proxy --build-arg http_proxy=$http_proxy -f comps/llms/src/text-generation/Dockerfile.intel_hpu_phi4 .
    if [ $? -ne 0 ]; then
        echo "opea/llm-textgen-phi4-gaudi built fail"
        exit 1
    else
        echo "opea/llm-textgen-phi4-gaudi built successful"
    fi
}

function start_service() {
    export TEXTGEN_PORT=10512 #10500-10599
    export host_ip=${host_ip}
    export LLM_MODEL_ID="/data/Phi-4-multimodal-instruct"
    export LOGFLAG=True
    export DATA_PATH="/data2/hf_model"

    cd $WORKPATH/comps/llms/deployment/docker_compose
    docker compose -f compose_text-generation.yaml up ${service_name} -d > ${LOG_PATH}/start_services_with_compose.log

    sleep 6m
}

function validate_services() {
    local URL="$1"
    local EXPECTED_RESULT="$2"
    local SERVICE_NAME="$3"
    local DOCKER_NAME="$4"
    local INPUT_DATA="$5"

    local HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST -d "$INPUT_DATA" -H 'Content-Type: application/json' "$URL")

    echo "==========================================="

    if [ "$HTTP_STATUS" -eq 200 ]; then
        echo "[ $SERVICE_NAME ] HTTP status is 200. Checking content..."

        local CONTENT=$(curl -s -X POST -d "$INPUT_DATA" -H 'Content-Type: application/json' "$URL" | tee ${LOG_PATH}/${SERVICE_NAME}.log)

        if echo "$CONTENT" | grep -q "$EXPECTED_RESULT"; then
            echo "[ $SERVICE_NAME ] Content is as expected."
        else
            echo "[ $SERVICE_NAME ] Content does not match the expected result: $CONTENT"
            docker logs ${DOCKER_NAME} >> ${LOG_PATH}/${SERVICE_NAME}.log
            exit 1
        fi
    else
        echo "[ $SERVICE_NAME ] HTTP status is not 200. Received status was $HTTP_STATUS"
        docker logs ${DOCKER_NAME} >> ${LOG_PATH}/${SERVICE_NAME}.log
        exit 1
    fi
    sleep 1s
}

function validate_microservices() {
    URL="http://${host_ip}:${TEXTGEN_PORT}/v1/chat/completions"

    # textgen
    echo "Validate textgen with string messages input..."
    validate_services \
        "$URL" \
        "text" \
        "$service_name" \
        "$service_name" \
        '{"model": "/data/Phi-4-multimodal-instruct", "messages": "What is Deep Learning?", "max_tokens":17, "stream":false}'

    # image
    echo "Validate textgen with image input..."
    validate_services \
        "$URL" \
        "text" \
        "$service_name" \
        "$service_name" \
        '{"model": "/data/Phi-4-multimodal-instruct", "messages": "What is shown in this image?", "image_path":"/data/testdata/australia.jpg", "max_tokens":17, "stream":false}'

    # audio
    echo "Validate textgen with audio input..."
    validate_services \
        "$URL" \
        "text" \
        "$service_name" \
        "$service_name" \
        '{"model": "/data/Phi-4-multimodal-instruct", "messages": "Based on the attached audio, generate a comprehensive text transcription of the spoken content.", "audio_path":"/data/testdata/what_is_the_traffic_sign_in_the_image.wav", "max_tokens":17, "stream":false}'
}

function stop_docker() {
    cd $WORKPATH/comps/llms/deployment/docker_compose
    docker compose -f compose_text-generation.yaml down ${service_name} --remove-orphans
}

function main() {

    stop_docker
    build_docker_images
    start_service
    validate_microservices
    stop_docker

    echo y | docker system prune

}

main
