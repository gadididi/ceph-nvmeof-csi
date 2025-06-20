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

package driver

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/container-storage-interface/spec/lib/go/csi"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"k8s.io/klog"
	"k8s.io/utils/mount"

	csicommon "github.com/ceph/ceph-nvmeof-csi/pkg/csi-common"
	"github.com/ceph/ceph-nvmeof-csi/pkg/util"
)

type nodeServer struct {
	csi.UnimplementedNodeServer
	defaultImpl *csicommon.DefaultNodeServer
	mounter     mount.Interface
	volumeLocks *util.VolumeLocks
}

func newNodeServer(d *csicommon.CSIDriver) (*nodeServer, error) {
	ns := &nodeServer{
		defaultImpl: csicommon.NewDefaultNodeServer(d),
		mounter:     mount.New(""),
		volumeLocks: util.NewVolumeLocks(),
	}

	return ns, nil
}

func (ns *nodeServer) NodeStageVolume(_ context.Context, req *csi.NodeStageVolumeRequest) (*csi.NodeStageVolumeResponse, error) {

	var err error
	if err = util.ValidateNodeStageVolumeRequest(req); err != nil {
		return nil, err
	}

	volumeID := req.GetVolumeId()
	unlock := ns.volumeLocks.Lock(volumeID)
	defer unlock()

	stagingParentPath := req.GetStagingTargetPath()
	stagingTargetPath := stagingParentPath + "/" + volumeID // use this directory to persistently store VolumeContext

	klog.Infof("NodeStageVolume called for volume %s, stagingTargetPath: %s", volumeID, stagingTargetPath)

	isStaged, err := ns.isStaged(stagingTargetPath)
	if err != nil {
		klog.Errorf("failed to check isStaged, targetPath: %s err: %v", stagingTargetPath, err)
		return nil, status.Error(codes.Internal, err.Error())
	}
	if isStaged {
		klog.Warning("volume already staged")
		return &csi.NodeStageVolumeResponse{}, nil
	}

	var initiator util.NvmeofCsiInitiator
	initiator, err = util.NewNvmeofCsiInitiator(req.GetPublishContext()) //TODO - make NvmeofCsiInitiator works
	if err != nil {
		klog.Errorf("failed to create spdk initiator, volumeID: %s err: %v", volumeID, err)
		return nil, status.Error(codes.Internal, err.Error())

	}
	devicePath, err := initiator.Connect() // idempotent
	if err != nil {
		klog.Errorf("failed to connect initiator, volumeID: %s err: %v", volumeID, err)
		return nil, status.Error(codes.Internal, err.Error())
	}
	defer func() {
		if err != nil {
			initiator.Disconnect() //nolint:errcheck // ignore error
		}
	}()
	if err = ns.stageVolume(devicePath, stagingTargetPath); err != nil { // idempotent
		klog.Errorf("failed to stage volume, volumeID: %s devicePath:%s err: %v", volumeID, devicePath, err)
		return nil, status.Error(codes.Internal, err.Error())
	}
	return &csi.NodeStageVolumeResponse{}, nil
}

func (ns *nodeServer) NodeUnstageVolume(_ context.Context, req *csi.NodeUnstageVolumeRequest) (*csi.NodeUnstageVolumeResponse, error) {
	volumeID := req.GetVolumeId()
	unlock := ns.volumeLocks.Lock(volumeID)
	defer unlock()

	stagingTargetPath := req.GetStagingTargetPath() + "/" + volumeID

	isStaged, err := ns.isStaged(stagingTargetPath)
	if err != nil {
		klog.Errorf("failed to check isStaged, targetPath: %s err: %v", stagingTargetPath, err)
		return nil, status.Error(codes.Internal, err.Error())
	}
	if !isStaged {
		klog.Warning("volume already unstaged")
		return &csi.NodeUnstageVolumeResponse{}, nil
	}

	err = ns.deleteMountPoint(stagingTargetPath) // idempotent
	if err != nil {
		klog.Errorf("failed to delete mount point, targetPath: %s err: %v", stagingTargetPath, err)
		return nil, status.Errorf(codes.Internal, "unstage volume %s failed: %s", volumeID, err)
	}
	//TODO - maybe we should disconnect the initiator here?
	// volumeContext, err := util.LookupVolumeContext(stagingTargetPath)
	// if err != nil {
	// 	klog.Errorf("failed to lookup volume context, volumeID: %s err: %v", volumeID, err)
	// 	return nil, status.Error(codes.Internal, err.Error())
	// }
	// var initiator util.NvmeofCsiInitiator
	// initiator, err = util.NewNvmeofCsiInitiator(volumeContext)
	// if err != nil {
	// 	klog.Errorf("failed to create spdk initiator, volumeID: %s err: %v", volumeID, err)
	// 	return nil, status.Error(codes.Internal, err.Error())
	// }
	// err = initiator.Disconnect() // idempotent
	// if err != nil {
	// 	klog.Errorf("failed to disconnect initiator, volumeID: %s err: %v", volumeID, err)
	// 	return nil, status.Error(codes.Internal, err.Error())
	// }
	// if err := util.CleanUpVolumeContext(stagingTargetPath); err != nil {
	// 	klog.Errorf("failed to clean up volume context, volumeID: %s err: %v", volumeID, err)
	// 	return nil, status.Error(codes.Internal, err.Error())
	// }
	return &csi.NodeUnstageVolumeResponse{}, nil
}

func (ns *nodeServer) NodePublishVolume(_ context.Context, req *csi.NodePublishVolumeRequest) (*csi.NodePublishVolumeResponse, error) {
	volumeID := req.GetVolumeId()
	stagingTargetPath := filepath.Join(req.GetStagingTargetPath(), volumeID)
	targetPath := req.GetTargetPath()

	// Lock per volume
	unlock := ns.volumeLocks.Lock(volumeID)
	defer unlock()

	if req.GetVolumeCapability().GetBlock() == nil {
		klog.Errorf("NodePublishVolume called with non-block volume capability, volumeID: %s", volumeID)
		return nil, status.Errorf(codes.InvalidArgument, "only block volumes supported")
	}

	// Create the target block file for bind-mount
	if _, err := ns.createMountPoint(targetPath); err != nil {
		return nil, status.Errorf(codes.Internal, "failed to create target mount point: %v", err)
	}
	// Bind-mount the block device to the target path
	klog.Infof("Binding staging path %s to target path %s for volume %s", stagingTargetPath, targetPath, volumeID)
	if err := ns.mounter.Mount(stagingTargetPath, targetPath, "", []string{"bind"}); err != nil {
		return nil, status.Errorf(codes.Internal, "bind mount failed: %v", err)
	}
	return &csi.NodePublishVolumeResponse{}, nil

}

func (ns *nodeServer) NodeUnpublishVolume(_ context.Context, req *csi.NodeUnpublishVolumeRequest) (*csi.NodeUnpublishVolumeResponse, error) {
	volumeID := req.GetVolumeId()
	unlock := ns.volumeLocks.Lock(volumeID)
	defer unlock()

	err := ns.deleteMountPoint(req.GetTargetPath()) // idempotent
	if err != nil {
		klog.Errorf("failed to delete mount point, targetPath: %s err: %v", req.GetTargetPath(), err)
		return nil, status.Error(codes.Internal, err.Error())
	}
	return &csi.NodeUnpublishVolumeResponse{}, nil
}

func (ns *nodeServer) NodeGetCapabilities(_ context.Context, _ *csi.NodeGetCapabilitiesRequest) (*csi.NodeGetCapabilitiesResponse, error) {
	return &csi.NodeGetCapabilitiesResponse{
		Capabilities: []*csi.NodeServiceCapability{
			{
				Type: &csi.NodeServiceCapability_Rpc{
					Rpc: &csi.NodeServiceCapability_RPC{
						Type: csi.NodeServiceCapability_RPC_STAGE_UNSTAGE_VOLUME,
					},
				},
			},
		},
	}, nil

}

func (ns *nodeServer) stageVolume(devicePath, stagingPath string) error {
	mounted, err := ns.createMountPoint(stagingPath)
	if err != nil {
		return err
	}
	if mounted {
		return nil
	}

	klog.Infof("Bind mounting block device %s to staging path %s", devicePath, stagingPath)
	err = ns.mounter.Mount(devicePath, stagingPath, "", []string{"bind"})
	if err != nil {
		return fmt.Errorf("failed to bind mount block device: %w", err)
	}
	return nil
}

// isStaged if stagingPath is a mount point, it means it is already staged, and vice versa
func (ns *nodeServer) isStaged(stagingPath string) (bool, error) {
	unmounted, err := mount.IsNotMountPoint(ns.mounter, stagingPath)
	if err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		klog.Warningf("check is stage error: %v", err)
		return true, err
	}
	return !unmounted, nil
}

// create mount point if not exists, return whether already mounted
func (ns *nodeServer) createMountPoint(path string) (bool, error) {
	unmounted, err := mount.IsNotMountPoint(ns.mounter, path)
	if os.IsNotExist(err) {
		unmounted = true

		dir := filepath.Dir(path)
		klog.Infof("Creating mount point %s", dir)
		if err := os.MkdirAll(dir, 0755); err != nil {
			return false, fmt.Errorf("failed to create parent dir for %s: %w", path, err)
		}

		// Create the file if it doesn't exist
		if _, err := os.Stat(path); os.IsNotExist(err) {
			klog.Infof("Creating block device target file %s", path)
			file, err := os.OpenFile(path, os.O_CREATE, 0o600)
			if err != nil {
				return false, fmt.Errorf("failed to create block device target file %s: %w", path, err)
			}
			file.Close()
		}
		err = nil // reset IsNotExist
	}
	if !unmounted {
		klog.Infof("%s already mounted", path)
	}
	return !unmounted, err
}

// unmount and delete mount point, must be idempotent
func (ns *nodeServer) deleteMountPoint(path string) error {
	unmounted, err := mount.IsNotMountPoint(ns.mounter, path)
	if os.IsNotExist(err) {
		klog.Infof("%s already deleted", path)
		return nil
	}
	if err != nil {
		return fmt.Errorf("failed to check mount point: %w", err)
	}

	if !unmounted {
		klog.Infof("Unmounting block device at %s", path)
		if err := ns.mounter.Unmount(path); err != nil {
			return fmt.Errorf("failed to unmount: %w", err)
		}
	}

	// Delete the block file
	klog.Infof("Removing mount point file %s", path)
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("failed to remove mount point file %s: %w", path, err)
	}

	// Optionally remove parent dir if empty
	dir := filepath.Dir(path)
	klog.Infof("Removing parent directory %s if empty", dir)
	if err := os.Remove(dir); err != nil && !os.IsNotExist(err) && !isDirNotEmpty(err) {
		// If the directory is not empty, that's okay — skip silently
		klog.Infof("Parent directory %s not empty, skipping delete", dir)
	}

	return nil
}

// Helper to check if the error is "directory not empty"
func isDirNotEmpty(err error) bool {
	return strings.Contains(err.Error(), "directory not empty")
}

func (ns *nodeServer) NodeGetInfo(ctx context.Context, req *csi.NodeGetInfoRequest) (*csi.NodeGetInfoResponse, error) {
	return ns.defaultImpl.NodeGetInfo(ctx, req)
}
