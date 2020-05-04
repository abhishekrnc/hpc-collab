#!/bin/bash

## $Header: $
## Source:
## @file cfg/provision/inc/cfgfs.h.sh

## @brief This header file defines common names and hierarchy of the configuration file system layout

HOSTNAME=${HOSTNAME:-$(hostname -s)}
isvirt=$(echo $(which virt-what 2>&1))
declare -x IN_CLUSTER=""

case "${isvirt}" in
  *"no virt-what in"*|*"not found"*|"")
      ## @todo clustername is derived from the file system hierarchy
      if [ -z "${CLUSTERNAME}" ] ; then
        echo "ANCHOR:${ANCHOR} set, but CLUSTERNAME is empty"
        exit 99
      fi
    ;;
  *)
     # default (obsolete)
     # declare -x VC=/vagrant
     declare -x CLUSTERNAME=${HOSTNAME:0:2}
     if [ -x ${isvirt} ] ; then
       declare -x  IN_CLUSTER=true
     fi
   ;;
esac

# inside the base host ("dom0"), ANCHOR is used.
# It should be set by the invoker and should be the root of this cluster's definition,
declare -x VC=${ANCHOR}/../$(basename ${PWD})

# inside the guest, the virtual cluster driver directory (ex. "vc") is mapped to /vagrant and/or /vc
# a two-character cluster abbreviation
# This location is unmounted once the node is fully provisioned.
if [ -n "${IN_CLUSTER}" ] ; then
  declare -x VC=/${CLUSTERNAME}
fi

declare -x CFG=${VC}/cfg
declare -x PROVISION_GENERIC=${CFG}/provision
declare -x VC_PROVISION_GENERIC=${PROVISION_GENERIC}
declare -x XFR=${VC}/xfr

# inside the guest, portions of this tree are replicated to HOMEVAGRANT
declare -x HOMEVAGRANT=/home/vagrant

# file system space that is synchronized among nodes is rooted in COMMON
declare -x COMMON=${HOMEVAGRANT}/common

# home directories HOME_BASEDIR
declare -x HOME_BASEDIR=${COMMON}/home

# configuration tree which remains even after full provisioning
declare -x CFG_HOMEVAGRANT=${HOMEVAGRANT}/cfg

# provisioning scripts, libaries, flags, drivers 
declare -x PROVISION_HOMEVAGRANT=${CFG_HOMEVAGRANT}/provision

# repositories shared among the cluster nodes COMMON_REPOS
declare -x COMMON_REPOS=${COMMON}/repos

# node-internal local repository
declare -x LOCALREPO=${VAGRANT}/etc/localrepo

# node-internal local repository definition
declare -x YUM_REPO_D=/etc/yum.repos.d
declare -x LOCAL_REPO_ID=local-vcbuild
declare -x YUM_LOCALREPO_DEF=${YUM_REPO_D}/${LOCAL_REPO_ID}.repo

# shared cluster-internal common repository
declare -x LOCALREPO_SUFFIX=/centos/7/local
declare -x COMMON_LOCALREPO=${COMMON_REPOS}${LOCALREPO_SUFFIX}

# shared provisioning scripts, libraries, flags, drivers
declare -x COMMON_PROVISION=${COMMON}/provision

declare -x ETC=/etc
declare -x ETCSLURM=/etc/slurm
declare -x ETCMUNGE=/etc/munge

declare -x VC_COMMON=${VC}/common

if [ -z "${VC}" ] ; then
  echo VC: empty
  exit 99
elif [ ! -d "${VC}" ] ; then
  echo VC:${VC} not a directory
  exit 99
fi

declare -x NODES=$(echo $(ls ${CFG} | grep -v provision))

declare -x ISOS="${XFR}"

declare -x VAGRANTFILE=${VC}/Vagrantfile
declare -x ROOT=${CFG}/${HOSTNAME}

declare -x SERVICES_D=${ROOT}/services
declare -x SERVICES_ON=${SERVICES_D}/on
declare -x SERVICES_OFF=${SERVICES_D}/off

declare -x RPM=${ROOT}/rpm
declare -x ROOTFS=${ROOT}/rootfs
declare -x REQUIREMENTS="${ROOT}/requires"
declare -x REPOS=${COMMON_REPOS}
declare -x FLAGS=""

for d in ${PROVISION_SRC_FLAG_D} ${PROVISION_GENERIC}/flag
do
  if [ ! -d ${d} ] ; then
    continue
  fi
  is_mounted=$(ls ${d})
  case "${is_mounted}" in
    *"NOT MOUNTED"*)		continue ;;
    *) export FLAGS=${d};	break	 ;;
  esac
done

if [ -z "${FLAGS}" ] ; then
  echo "$0:"
  echo " PWD: " $(pwd)
  echo "  FLAGS: cannot locate flag directory: "
  echo "    not PROVISION_SRC_FLAG_D:${PROVISION_SRC_FLAG_D},"
  echo "    not PROVISION_GENERIC:${PROVISION_GENERIC}/flag"
  exit 99
fi

declare -x ENV=${PROVISION_GENERIC}/env

declare -x USERADD=${COMMON_PROVISION}/useradd
declare -x USERADD_PASSWD=./passwd
declare -x USERADD_PASSWD_CLEARTEXT=${USERADD_PASSWD}/cleartext
declare -x USERADD_PASSWD_ENCRYPTED=${USERADD_PASSWD}/encrypted

declare -x SUDOERS_D="sudoers.d"
declare -x ETC_SUDOERS_D=/etc/${SUDOERS_D}

declare -x MNT="/mnt"
declare -x TMP="/tmp"

declare -x BUILDWHAT=build
declare -x INSTALLWHAT=${CFG}/${HOSTNAME}/install
declare -x CONFIGWHAT=${CFG}/${HOSTNAME}/config
declare -x VERIFYWHAT=${CFG}/${HOSTNAME}/verify

declare -x BUILDWHERE=${HOMEVAGRANT}/build
declare -x RPMS_ARCH=rpmbuild/RPMS/${ARCH}
declare -x RPMS_MANIFEST=RPMS.Manifest

declare -x STATE_D=${VC_COMMON}/._state
declare -x STATE_RUNNING=${STATE_D}/running
declare -x STATE_PROVISIONED=${STATE_D}/provisioned
declare -x STATE_POWEROFF=${STATE_D}/poweroff
declare -x STATE_NONEXISTENT=${STATE_D}/nonexistent
