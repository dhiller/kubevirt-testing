Kubevirt Testing
================

Contains stuff to test KubeVirt i.e. on an openshift cluster.

hack/kubevirt-testing.sh
------------------------

Script to deploy and test kubevirt on an openshift cluster.

Usage examples:

Testing a certain kubevirt release, i.e. `0.45.0`

```bash
export BIN_DIR=/tmp/<your-bin-dir>
export DOCKER_PREFIX=quay.io/kubevirt
export DOCKER_TAG="v0.45.0"
./hack/kubevirt-testing.sh deploy_release "v0.45.0"
./hack/kubevirt-testing.sh run_tests
```

is same as

```bash
export BIN_DIR=/tmp/<your-bin-dir>
export DOCKER_PREFIX=quay.io/kubevirt
./hack/kubevirt-testing.sh test_kubevirt_release "0.45"
```

also we can then

```bash
./hack/kubevirt-testing.sh undeploy_release "v0.45.0"
```

Testing the nightly build

```bash
export BIN_DIR=/tmp/<your-bin-dir>
./hack/kubevirt-testing.sh test_kubevirt_nightly
```

is the same as

```bash
export BIN_DIR=/tmp/<your-bin-dir>
./hack/kubevirt-testing.sh deploy_kubevirt_nightly_test_setup
./hack/kubevirt-testing.sh run_tests
```

also we can then

```bash
./hack/kubevirt-testing.sh undeploy_kubevirt_nightly_test_setup
```
