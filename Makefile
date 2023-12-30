ROOT=$(shell pwd)
BIN_DIR ?= $(ROOT)/bin
DATE ?= $(shell date +'%Y-%m-%dT%H:%M:%SZ')
VERSION ?= $(shell git describe --tags)
COMMIT ?= $(shell git log -1 --pretty=format:"%h")

build: bindir ctrshim

bindir:
	mkdir -p $(BIN_DIR)
	mkdir -p $(BIN_DIR)/macos

ctrshim:
	nim c -d:VERSION=$(VERSION) -d:COMMIT=$(COMMIT) -d:BUILDDATE=$(DATE) $(ROOT)/src/ctrshim.nim
	mv $(ROOT)/src/ctrshim $(BIN_DIR)/
