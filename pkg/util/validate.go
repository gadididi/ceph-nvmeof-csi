/*
Copyright 2025 The ceph-nvmeof-csi Authors.

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
	"github.com/container-storage-interface/spec/lib/go/csi"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// ValidateNodeStageVolumeRequest validates the node stage request.
func ValidateNodeStageVolumeRequest(req *csi.NodeStageVolumeRequest) error {
	if req.GetVolumeCapability() == nil {
		return status.Error(codes.InvalidArgument, "volume capability missing in request")
	}

	if req.GetVolumeId() == "" {
		return status.Error(codes.InvalidArgument, "volume ID missing in request")
	}

	if req.GetStagingTargetPath() == "" {
		return status.Error(codes.InvalidArgument, "staging target path missing in request")
	}

	// if req.GetSecrets() == nil || len(req.GetSecrets()) == 0 { //TODO - not use?
	// 	return status.Error(codes.InvalidArgument, "stage secrets cannot be nil or empty")
	// }

	// validate stagingpath exists
	ok := checkDirExists(req.GetStagingTargetPath())
	if !ok {
		return status.Errorf(
			codes.InvalidArgument,
			"staging path %s does not exist on node",
			req.GetStagingTargetPath())
	}

	return nil
}
