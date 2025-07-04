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

package main

import (
	"flag"
	"os"

	"k8s.io/klog"

	"github.com/ceph/ceph-nvmeof-csi/pkg/driver"
	"github.com/ceph/ceph-nvmeof-csi/pkg/util"
)

const (
	driverName    = "csi.nvmeof.io"
	driverVersion = "0.1.0"
)

var conf = util.Config{
	DriverVersion: driverVersion,
}

func init() {
	flag.StringVar(&conf.DriverName, "drivername", driverName, "Name of the driver")
	flag.StringVar(&conf.Endpoint, "endpoint", "unix://tmp/nvmeofcsi.sock", "CSI endpoint")
	flag.StringVar(&conf.NodeID, "nodeid", "", "node id")
	flag.BoolVar(&conf.IsControllerServer, "controller", true, "Start controller server")
	flag.BoolVar(&conf.IsNodeServer, "node", false, "Start node server")

	klog.InitFlags(nil)
	if err := flag.Set("logtostderr", "true"); err != nil {
		klog.Exitf("failed to set logtostderr flag: %v", err)
	}
	flag.Parse()
}

func main() {
	klog.Infof("Starting NvmeOF-CSI driver: %v version: %v", conf.DriverName, driverVersion)

	driver.Run(&conf)

	os.Exit(0)
}
