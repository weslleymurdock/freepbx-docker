#!/bin/bash

systemctl daemon-reload
systemctl reset-failed freepbx-docker.service
systemctl restart freepbx-docker.service

