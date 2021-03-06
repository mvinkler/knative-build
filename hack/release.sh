#!/usr/bin/env bash

# Copyright 2018 The Knative Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

source $(dirname $0)/../vendor/github.com/knative/test-infra/scripts/release.sh

set -o errexit
set -o pipefail

# Script entry point
parse_flags $@

# Set default GCS/GCR
: ${BUILD_RELEASE_GCS:="knative-releases/build"}
: ${BUILD_RELEASE_GCR:="gcr.io/knative-releases"}
readonly BUILD_RELEASE_GCS
readonly BUILD_RELEASE_GCR

# Location of the base image for creds-init and git images
if (( PUBLISH_RELEASE )); then
  BUILD_BASE_REGISTRY="$(echo $BUILD_RELEASE_GCR | cut -d/ -f1)"
else
  BUILD_BASE_REGISTRY="ko.local"
fi

BUILD_BASE_REPO="$(echo $BUILD_RELEASE_GCR | cut -d/ -f2-)/github.com/knative/build/build-base"

readonly BUILD_BASE_REGISTRY
readonly BUILD_BASE_REPO

# Local generated yaml file
readonly OUTPUT_YAML=release.yaml

function bazel_cleanup() {
  bazel clean --expunge
}

function ko_build() {
  echo "Building build-crd"
  ko resolve ${KO_FLAGS} -f config/ > ${OUTPUT_YAML}
  tag_images_in_yaml ${OUTPUT_YAML} ${BUILD_RELEASE_GCR} ${TAG}

  echo "New release built successfully"
}

trap bazel_cleanup EXIT

run_validation_tests ./test/presubmit-tests.sh

banner "Building the release"

echo "Building base images"
# Build the base image for creds-init and git images.
bazel build \
  --define registry=${BUILD_BASE_REGISTRY} \
  --define repository=${BUILD_BASE_REPO} \
  //images:all

# Set the repository
export KO_DOCKER_REPO=${BUILD_RELEASE_GCR}
# Build should not try to deploy anything, use a bogus value for cluster.
export K8S_CLUSTER_OVERRIDE=CLUSTER_NOT_SET
export K8S_USER_OVERRIDE=USER_NOT_SET
export DOCKER_REPO_OVERRIDE=DOCKER_NOT_SET

if (( ! PUBLISH_RELEASE )); then
  ko_build
  exit 0
fi

echo "- Destination GCR: ${BUILD_RELEASE_GCR}"
echo "- Destination GCS: ${BUILD_RELEASE_GCS}"

# Push the base image for creds-init and git images. We push the
# images first so that ko_build will pick up the latest changes
echo "Pushing base images to ${BUILD_BASE_REGISTRY}/${BUILD_BASE_REPO}"
bazel run \
  --define registry=${BUILD_BASE_REGISTRY} \
  --define repository=${BUILD_BASE_REPO} \
  //images:push-build-base

bazel run \
  --define registry=${BUILD_BASE_REGISTRY} \
  --define repository=${BUILD_BASE_REPO} \
  //images:push-build-base-debug

ko_build

echo "Publishing ${OUTPUT_YAML}"
publish_yaml ${OUTPUT_YAML} ${BUILD_RELEASE_GCS} ${TAG}

echo "New release published successfully"

# TODO(mattmoor): Create other aliases?
