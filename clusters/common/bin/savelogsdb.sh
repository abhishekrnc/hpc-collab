#!/bin/bash

## $Header: $
## Source:
## @file cfg/provision/bin/markprovisioned.sh

## This ANCHOR is used because the shell loader may be called from the primary host ("dom0") or from the guest host ("/vagrant/...")
declare -x VC=${VC:-_VC_UNSET_}

if [ ${VC} = "_VC_UNSET_" ] ; then
  echo ${0}: VC is unset. Need virtual cluster identifier.
  exit 97
fi

#declare -x ANCHOR=cfg/provision
declare -x ANCHOR=../common
declare -x LOADER_SHLOAD=${ANCHOR}/loader/shload.sh
declare -x BASEDIR=${ANCHOR}/..

if [ -z "${LOADER_SHLOAD}" ] ; then
  echo "${0}: empty: LOADER_SHLOAD"
  exit 98
fi

if [ ! -f "${LOADER_SHLOAD}" ] ; then
  echo "${0}: nonexistent: LOADER_SHLOAD:${LOADER_SHLOAD}"
  exit 99
fi
source ${LOADER_SHLOAD}

declare -x PWD=$(pwd)
declare -x ID=$(id -n -u)
declare -x IAM=$(basename $0 .sh)
declare -x TSTAMP=$(date +%Y.%m.%d.%H%M)
declare -x REQUESTED_HOST=${1-""}
declare -x VARLOG=/var/log
declare -x TMPDIR=${TMPDIR:-/tmp/${IAM}.${TSTAMP}.d}
declare -x STORAGE_HOST=""
declare -x DB_HOST=""
declare -x SSH_OPTARGS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
declare -x PROVISIONED_D=common/._state/provisioned

SaveLogs() {
  Rc ErrExit ${EX_OSFILE} "mkdir -p ${TMPDIR}"
  local _vc=$(echo $(basename $(cd ${VC}; pwd)))

  any_up=""
  for d in ${PWD}/${PROVISIONED_D}/*
  do
    any_up="${any_up} $(basename ${d})"
  done
  any_up=$(echo ${any_up} | sed 's/..[0-9] //g')
  if [ -z "${any_up}" ] ; then
    ErrExit ${EX_CONFIG} "any_up: empty?"
  fi

  _h=${any_up:0:2}fs
  export STORAGE_HOST=${_h}
  export DB_HOST=${any_up:0:2}db

  Rc ErrExit  ${EX_CONFIG} "ping -n -q -w 1 ${_h}"
  Rc ErrExit ${EX_CONFIG} "ssh -q ${SSH_OPTARGS} ${_h} true"
  Rc ErrExit ${EX_CONFIG} "mkdir -p ${TMPDIR}/${_h}"

  LOGDIRS=( ${LOGDIRS} )
  for _l in ${VARLOG}/slurm ${VARLOG}/rsyslog
  do
    local _t=$(basename ${_l})
    Rc ErrExit ${EX_OSFILE} "mkdir -p ${TMPDIR}/${_h}/${_t}"
    Rc ErrExit ${EX_OSFILE} "scp -Bpq ${SSH_OPTARGS} ${_h}:${_l}/* ${TMPDIR}/${_h}/${_t}/"
  done
  return
}

SaveDB() {

  if [ -z "${DB_HOST}" ] ; then
    ErrExit ${EX_CONFIG} "DB_HOST: empty"
  fi

  MYSQLDUMP_ARGS="--single-transaction --opt --dump-date --flush-logs --quick --user=root"
  MYSQLDUMP_CMD="/usr/bin/mysqldump"
  MYSQLDUMP_DB="slurm_acct_db"
  DUMPFILE=/tmp/slurm_acct_db.${TSTAMP}.sql
  MYSQLDUMP="${MYSQLDUMP_CMD} ${MYSQLDUMP_ARGS} ${MYSQLDUMP_DB}"

  _h=${DB_HOST}
  Rc ErrExit ${EX_CONFIG} "ping -n -q -w 1 ${_h}"
  Rc ErrExit ${EX_CONFIG} "ssh -q ${SSH_OPTARGS} ${_h} true"
  Rc ErrExit ${EX_CONFIG} "mkdir -p ${TMPDIR}/${_h}"
  Rc ErrExit ${EX_OSFILE} "ssh -q ${SSH_OPTARGS} ${_h} ${MYSQLDUMP} > ${DUMPFILE}"
  Rc ErrExit ${EX_OSFILE} "mv ${DUMPFILE} ${TMPDIR}/${_h}/"
  return
}

CompressLogs() {
  Rc ErrExit ${EX_SOFTWARE} "find ${TMPDIR} -type f -not -name \*.gz -exec gzip \{\} \;"
  return
}

main() {
  SetFlags >/dev/null 2>&1
  local _vc=$(echo $(basename $(cd ${VC}; pwd)))
  SaveLogs
  SaveDB
  CompressLogs
  echo "${_vc} logs: ${TMPDIR}"
  trap '' 0
  exit ${EX_OK}
}

main $@

ErrExit ${EX_SOFTWARE} "FAULTHROUGH"
exit ${EX_SOFTWARE}
