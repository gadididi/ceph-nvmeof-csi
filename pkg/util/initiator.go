/*
Copyright (c) Arm Limited and Contributors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package util

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"k8s.io/klog"
)

// NvmeofCsiInitiator defines interface for NVMeoF/iSCSI initiator
//   - Connect initiates target connection and returns local block device filename
//     e.g., /dev/disk/by-id/nvme-SPDK_Controller1_SPDK00000000000001
//   - Disconnect terminates target connection
//   - Caller(node service) should serialize calls to same initiator
//   - Implementation should be idempotent to duplicated requests
type NvmeofCsiInitiator interface {
	Connect() (string, error)
	Disconnect() error
}

func NewNvmeofCsiInitiator(publishContext map[string]string) (NvmeofCsiInitiator, error) {
	if publishContext == nil {
		return nil, fmt.Errorf("publishContext is nil")
	}
	if publishContext["transport"] == "" || publishContext["traddr"] == "" ||
		publishContext["trsvcid"] == "" || publishContext["nqn"] == "" || publishContext["uuid"] == "" {
		return nil, fmt.Errorf("publishContext missing required fields: %v", publishContext)
	}
	return &initiatorNVMf{
		// see util/nvmf.go VolumeInfo()
		targetType: publishContext["transport"],
		targetAddr: publishContext["traddr"],
		targetPort: publishContext["trsvcid"],
		nqn:        publishContext["nqn"],
		uuid:       publishContext["uuid"],
	}, nil
}

// NVMf initiator implementation
type initiatorNVMf struct {
	targetType string
	targetAddr string
	targetPort string
	nqn        string
	uuid       string
}

func (nvmf *initiatorNVMf) Connect() (string, error) {
	cmdLine := []string{
		"nvme", "connect-all", "-t", strings.ToLower(nvmf.targetType),
		"-a", nvmf.targetAddr, "-q", nvmf.nqn, "-l", "1800",
	}
	output, err := execWithTimeout(cmdLine, 40)

	if err != nil {
		if strings.Contains(output, "already connected") {
			klog.Warningf("nvme connect: already connected to volume %s, continuing", nvmf.nqn)
		} else {
			klog.Errorf("command %v failed: %s", cmdLine, err)

		}
	}

	deviceGlob := fmt.Sprintf("/dev/disk/by-id/nvme-uuid.*%s*", nvmf.uuid)
	devicePath, err := waitForDeviceReady(deviceGlob, 20)
	if err != nil {
		return "", err
	}
	return devicePath, nil
}

func (nvmf *initiatorNVMf) Disconnect() error {
	// nvme disconnect -n "nqn"
	cmdLine := []string{"nvme", "disconnect", "-n", nvmf.nqn}
	_, err := execWithTimeout(cmdLine, 40)
	if err != nil {
		// go on checking device status in case caused by duplicate request
		klog.Errorf("command %v failed: %s", cmdLine, err)
	}

	deviceGlob := fmt.Sprintf("/dev/disk/by-id/nvme-uuid.*%s*", nvmf.uuid)
	return waitForDeviceGone(deviceGlob)
}

// when timeout is set as 0, try to find the device file immediately
// otherwise, wait for device file comes up or timeout
func waitForDeviceReady(deviceGlob string, seconds int) (string, error) {
	for i := 0; i <= seconds; i++ {
		matches, err := filepath.Glob(deviceGlob)
		if err != nil {
			return "", err
		}
		// two symbol links under /dev/disk/by-id/ to same device
		if len(matches) >= 1 {
			return matches[0], nil
		}
		time.Sleep(time.Second)
	}
	return "", fmt.Errorf("timed out waiting device ready: %s", deviceGlob)
}

// wait for device file gone or timeout
func waitForDeviceGone(deviceGlob string) error {
	for i := 0; i <= 20; i++ {
		matches, err := filepath.Glob(deviceGlob)
		if err != nil {
			return err
		}
		if len(matches) == 0 {
			return nil
		}
		time.Sleep(time.Second)
	}
	return fmt.Errorf("timed out waiting device gone: %s", deviceGlob)
}

// exec shell command with timeout(in seconds)
func execWithTimeout(cmdLine []string, timeout int) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeout)*time.Second)
	defer cancel()

	klog.Infof("running command: %v", cmdLine)
	//nolint:gosec // execWithTimeout assumes valid cmd arguments
	cmd := exec.CommandContext(ctx, cmdLine[0], cmdLine[1:]...)
	output, err := cmd.CombinedOutput()
	outputStr := string(output)
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return outputStr, fmt.Errorf("timed out")
	}
	if output != nil {
		klog.Infof("command returned: %s", output)
	}
	return outputStr, err
}
