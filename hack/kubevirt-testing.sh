#!/usr/bin/env bash
set -exuo pipefail

gcsweb_base_url="https://gcsweb.ci.kubevirt.io/gcs/kubevirt-prow"
testing_resources=(disks-images-provider.yaml local-block-storage.yaml rbac-for-testing.yaml uploadproxy-nodeport.yaml)

disk_manifest_file="${BIN_DIR:?}/disk-rhel.yaml"
kubevirt_testing_configuration_file="${BIN_DIR:?}/kubevirt-testing-configuration.json"

function setup_resources() {
    cat <<EOF >"$kubevirt_testing_configuration_file"
{
  "storageClassLocal": "managed-premium",
  "storageClassHostPath": "managed-premium",
  "storageClassRhel": "managed-premium",
  "storageClassWindows": "managed-premium",
  "storageClassBlockVolume": "managed-premium",
  "storageClassHostPathSeparateDevice": "managed-premium",
  "manageStorageClasses": true
}
EOF

    cat <<EOF >"$disk_manifest_file"
apiVersion: v1
kind: PersistentVolume
metadata:
  name: disk-rhel
  labels:
    kubevirt.io/test: "rhel"
spec:
  capacity:
    storage: 15Gi
  accessModes:
  - ReadWriteOnce
  nfs:
    server: "nfs"
    path: /
  storageClassName: managed-premium
EOF
}

function enable_cpu_manager() {
    oc patch machineconfigpool worker --type merge -p '{"metadata": {"labels": { "custom-kubelet": "cpumanager-enabled" }}}'
    oc create -f - <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: cpumanager-enabled
spec:
  machineConfigPoolSelector:
    matchLabels:
      custom-kubelet: cpumanager-enabled
  kubeletConfig:
     cpuManagerPolicy: static
     cpuManagerReconcilePeriod: 5s
EOF
}

function wait_for_cpumanager_label() {
    until [ $(oc get nodes --no-headers -l kubevirt.io/schedulable=true,cpumanager=true | wc -l) -gt 1 ]; do
        echo "Waiting until cpu manager is active"
        sleep 10
    done
    echo "cpu manager is active"
}

function test_release() {
    release="$(get_release_tag_for_xy "$1")"
    export DOCKER_TAG="$release"
    run_tests
}

function get_release_tag_for_xy() {
    release_xy="$1"

    curl --fail -s https://api.github.com/repos/kubevirt/kubevirt/releases |
        jq -r '(.[].tag_name | select( test("-(rc|alpha|beta)") | not ) )' |
        sort -rV | grep "v$release_xy" | head -1
}

function deploy_latest_cdi_release() {
    cdi_release_tag=$(curl -L -H'Accept: application/json' 'https://github.com/kubevirt/containerized-data-importer/releases/latest' | jq -r '.tag_name')
    oc create -f "https://github.com/kubevirt/containerized-data-importer/releases/download/${cdi_release_tag}/cdi-operator.yaml"
    oc create -f "https://github.com/kubevirt/containerized-data-importer/releases/download/${cdi_release_tag}/cdi-cr.yaml"

    # enable featuregate
    oc patch cdi cdi --type merge -p '{"spec": {"config": {"featureGates": [ "HonorWaitForFirstConsumer" ]}}}'
}

function undeploy_latest_cdi_release() {
    cdi_release_tag=$(curl -L -H'Accept: application/json' 'https://github.com/kubevirt/containerized-data-importer/releases/latest' | jq -r '.tag_name')
    oc delete --ignore-not-found=true -f "https://github.com/kubevirt/containerized-data-importer/releases/download/${cdi_release_tag}/cdi-cr.yaml" || true
    oc delete --ignore-not-found=true -f "https://github.com/kubevirt/containerized-data-importer/releases/download/${cdi_release_tag}/cdi-operator.yaml"
}

function deploy_release_test_setup() {
    release="$(get_release_tag_for_xy "$1")"
    export DOCKER_TAG="$release"

    setup_resources
    tagged_release_url="https://github.com/kubevirt/kubevirt/releases/download/${release}"

    oc create -f "$disk_manifest_file"

    curl -Lo "$BIN_DIR/tests.test" "${tagged_release_url}/tests.test"
    chmod +x "$BIN_DIR/tests.test"

    curl -L "${tagged_release_url}/kubevirt-operator.yaml" | oc create -f -
    curl -L "${tagged_release_url}/kubevirt-cr.yaml" | oc create -f -

    deploy_latest_cdi_release

    testing_infra_url="$gcsweb_base_url/devel/release/kubevirt/kubevirt/${release}/manifests/testing"
    for testing_resource in "${testing_resources[@]}"; do
        curl -L "${testing_infra_url}/${testing_resource}" | oc create -f -
    done

    until wait_on_cdi_ready && wait_on_kubevirt_ready; do sleep 5; done
}

function undeploy_release_test_setup() {
    release="$(get_release_tag_for_xy "$1")"
    export DOCKER_TAG="$release"

    tagged_release_url="https://github.com/kubevirt/kubevirt/releases/download/${release}"

    oc delete --ignore-not-found=true -f "$disk_manifest_file"

    testing_infra_url="$gcsweb_base_url/devel/release/kubevirt/kubevirt/${release}/manifests/testing"
    for testing_resource in "${testing_resources[@]}"; do
        curl -L "${testing_infra_url}/${testing_resource}" | oc delete --ignore-not-found=true -f -
    done

    undeploy_latest_cdi_release

    curl -L "${tagged_release_url}/kubevirt-cr.yaml" | oc delete --ignore-not-found=true -f - || true
    curl -L "${tagged_release_url}/kubevirt-operator.yaml" | oc delete --ignore-not-found=true -f -

    oc delete --ignore-not-found=true -f "$disk_manifest_file"
}

function get_latest_release_tag_for_kubevirt_nightly() {
    local release_url
    release_date=$(get_latest_release_date_for_nightly)
    release_url="$(get_release_url_for_nightly "$release_date")"

    echo "$(get_release_tag_for_nightly "$release_url" "$release_date")"
}

function test_nightly() {
    export DOCKER_PREFIX='quay.io/kubevirt'
    DOCKER_TAG="$(get_latest_release_tag_for_kubevirt_nightly)"
    export DOCKER_TAG
    run_tests
}

function deploy_nightly_test_setup() {
    local release_url
    release_date=$(get_latest_release_date_for_nightly)
    release_url="$(get_release_url_for_nightly "$release_date")"

    setup_resources

    oc create -f "$disk_manifest_file"

    curl -Lo "$BIN_DIR/tests.test" "${release_url}/testing/tests.test"
    chmod +x "$BIN_DIR/tests.test"

    oc create -f "${release_url}/kubevirt-operator.yaml"
    oc create -f "${release_url}/kubevirt-cr.yaml"

    deploy_latest_cdi_release

    for testing_resource in "${testing_resources[@]}"; do
        oc create -f "${release_url}/testing/${testing_resource}"
    done

    until wait_on_cdi_ready && wait_on_kubevirt_ready; do sleep 5; done
}

function wait_on_cdi_ready() {
    oc wait -n cdi cdi cdi --for=condition=Available --timeout=180s
}

function wait_on_kubevirt_ready() {
    oc wait -n kubevirt kv kubevirt --for condition=Available --timeout 15m
}

function undeploy_nightly_test_setup() {
    local release_url
    release_date=$(get_latest_release_date_for_nightly)
    release_url="$(get_release_url_for_nightly "$release_date")"

    oc delete --ignore-not-found=true -f "$disk_manifest_file"

    for testing_resource in "${testing_resources[@]}"; do
        oc delete --ignore-not-found=true -f "${release_url}/testing/${testing_resource}"
    done

    undeploy_latest_cdi_release

    oc delete --ignore-not-found=true -f "${release_url}/kubevirt-cr.yaml"
    oc delete --ignore-not-found=true -f "${release_url}/kubevirt-operator.yaml"

    oc delete --ignore-not-found=true -f "$disk_manifest_file"
}

function get_release_tag_for_nightly() {
    release_url="$1"
    release_date="$2"
    commit=$(curl -L "${release_url}/commit")
    echo "${release_date}_$(echo "${commit}" | cut -c 1-9)"
}

function get_release_url_for_nightly() {
    release_base_url="$gcsweb_base_url/devel/nightly/release/kubevirt/kubevirt"
    release_date="$1"
    echo "${release_base_url}/${release_date}"
}

function get_latest_release_date_for_nightly() {
    release_base_url="$gcsweb_base_url/devel/nightly/release/kubevirt/kubevirt"
    release_date=$(curl -L "${release_base_url}/latest")
    echo "${release_date}"
}

function get_path_or_empty_string_for_cmd() {
    cmd="$1"
    set +e
    which "$cmd"
    set -e
}

function run_tests() {
    mkdir -p "$ARTIFACT_DIR"
    # required to be set for test binary
    export ARTIFACTS=${ARTIFACT_DIR}

    OC_PATH=$(get_path_or_empty_string_for_cmd oc)
    KUBECTL_PATH=$(get_path_or_empty_string_for_cmd kubectl)

    set +u
    additional_test_args=""
    if [ -n "$KUBEVIRT_E2E_SKIP" ] || [ -n "$KUBEVIRT_E2E_FOCUS" ]; then
        if [ -n "$KUBEVIRT_E2E_SKIP" ]; then
            additional_test_args="${additional_test_args} -ginkgo.skip=${KUBEVIRT_E2E_SKIP}"
        fi
        if [ -n "$KUBEVIRT_E2E_FOCUS" ]; then
            additional_test_args="${additional_test_args} -ginkgo.focus=${KUBEVIRT_E2E_FOCUS}"
        fi
    elif [ -n "$KUBEVIRT_TESTS_FOCUS" ]; then
        additional_test_args="$KUBEVIRT_TESTS_FOCUS"
    fi
    kubevirt_testing_configuration=${KUBEVIRT_TESTING_CONFIGURATION:-${kubevirt_testing_configuration_file}}
    set -u

    tests.test -v=5 \
        -config=${kubevirt_testing_configuration} \
        -kubeconfig=${KUBECONFIG} \
        -container-tag=${DOCKER_TAG} \
        -container-tag-alt= \
        -container-prefix=${DOCKER_PREFIX} \
        -image-prefix-alt=-kv \
        -oc-path=${OC_PATH} \
        -kubectl-path=${KUBECTL_PATH} \
        -gocli-path="$(pwd)/cluster-up/cli.sh" \
        -test.timeout 420m \
        -ginkgo.noColor \
        -ginkgo.succinct \
        -ginkgo.slowSpecThreshold=60 \
        ${additional_test_args} \
        -junit-output=${ARTIFACT_DIR}/junit.functest.xml \
        -installed-namespace=kubevirt \
        -previous-release-tag= \
        -previous-release-registry=quay.io/kubevirt \
        -deploy-testing-infra=false \
        -apply-default-e2e-configuration=true
}

export PATH="$BIN_DIR:$PATH"
eval "$@"
