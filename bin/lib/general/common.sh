#!/usr/bin/env bash
# General Common — shared functions for all generals

# GENERAL_DOMAIN must be set before sourcing this file

_GENERAL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_GENERAL_LIB_DIR/../runtime/engine.sh"
source "$_GENERAL_LIB_DIR/prompt-builder.sh"
source "$_GENERAL_LIB_DIR/task-selection.sh"
source "$_GENERAL_LIB_DIR/workspace.sh"
source "$_GENERAL_LIB_DIR/memory.sh"
source "$_GENERAL_LIB_DIR/soldier-lifecycle.sh"
source "$_GENERAL_LIB_DIR/results.sh"
source "$_GENERAL_LIB_DIR/main-loop.sh"
