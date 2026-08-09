# K0s edge backup module

This module is a stripped down version of the main module, intended for external non pxc k0s edge systems, that only use zfs csi underneath.

It configures backup cron jobs and the ability for restores, funneling backups to any bdd server (pxc integrated / external).
