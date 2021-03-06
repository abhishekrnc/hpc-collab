#!/bin/bash

## $Header: $
## Source:
## @file cfg/provision/bin/provision.sh

## This file contains the main driver for the provisioning functions and libraries.


## The following cannot be in a sub-function in order for source <___> to have global scope, ex. EX_OK, etc.
declare -x PROVISION_SRC_D=/vagrant/cfg/provision

declare -x PROVISION_SRC_LIB_D=${PROVISION_SRC_D}/lib
declare -x PROVISION_SRC_INC_D=${PROVISION_SRC_D}/inc
declare -x PROVISION_SRC_ENV_D=${PROVISION_SRC_D}/env

if [ -d ${PROVISION_SRC_INC_D} ] ; then
  declare -x SH_HEADERS=$(ls ${PROVISION_SRC_INC_D})
fi
if [ -d ${PROVISION_SRC_ENV_D} ] ; then
  declare -x SH_ENV=$(ls ${PROVISION_SRC_ENV_D})
fi
if [ -d ${PROVISION_SRC_LIB_D} ] ; then
  declare -x SH_LIBS=$(ls ${PROVISION_SRC_LIB_D})
fi

# EX_SOFTWARE and EX_OK are needed if initial loader linkage fails
declare -x EX_SOFTWARE=70
declare -x EX_OK=0

flagfile="∕vagrant:\ NOT\ MOUNTED"
if [ ! -d /vagrant ] ; then
  echo " /vagrant: not a directory"
  exit ${EX_OK}
fi

flagfile="∕vagrant:\ NOT\ MOUNTED"
if [ -f "/vagrant/${flagfile}" ] ; then
  Verbose " already provisioned? ${VC}/${flagfile} exists"
  exit ${EX_OK}
fi

for _d in ${PROVISION_SRC_D} ${PROVISION_SRC_LIB_D} ${PROVISION_SRC_INC_D} ${PROVISION_SRC_ENV_D}
do
  if [ ! -d ${_d} ] ; then
    mount /vagrant || exit ${EX_SOFTWARE}
    exec ${0} || exit ${EX_SOFTWARE}
  fi
done

if [ \( -z "${SH_HEADERS}" \) -o \( -z "${SH_LIBS}" \) -o \( -z "${SH_ENV}" \) ] ; then
  echo -e "$(basename ${0}): broken linkage, empty SH_HEADERS:${SH_HEADERS}, SH_LIBS:${SH_LIBS}, SH_ENV:${SH_ENV}"
  exit ${EX_SOFTWARE}
fi

## @brief This defines the provisioning order of operations. In some cases, especially those requiring
## custom configuration, it may be appropriate to rearrange the provisioning order of operations.

# Order of functions called
# @todo future allow main option parsing to trigger which or an arbitrary selection of these to enable severable debuggability

# This structure allows us (eventually) to invoke each of these separately
# for debugging and/or unprovisioning.

declare -x CORE_ORDER_OF_OPERATIONS="SetFlags VerifyEnv VagrantDefaultProvider SetupSecondDisk    \
                                     CopyHomeVagrant CopyCommonProvision OverlayRootFS            \
                                     AppendFilesRootFS CreateNFSMountPoints InstallEarlyRPMS      \
                                     ConfigureLocalRepos WaitForPrerequisites InstallRPMS         \
                                     BuildSW InstallLocalSW ConfigSW SetServices UserAdd VerifySW \
                                     UpdateRPMS MarkNodeProvisioned UserVerificationJobs          "

declare -x DEBUG_DEFAULT_ORDER_OF_OPERATIONS="DebugNote VerbosePWD ClearSELinuxEnforce ${CORE_ORDER_OF_OPERATIONS}"


declare -x NORMAL_ORDER_OF_OPERATIONS="${CORE_ORDER_OF_OPERATIONS} FlagSlashVagrant"

declare -x REPO_DISK=/dev/sdb
declare -x REPO_PART=${REPO_DISK}1

## yes, there's a bash one-liner to do this, but no, this may be more readable
if [ -n "${DEBUG}" ] ; then
  declare -x DEFAULT_ORDER_OF_OPERATIONS=${DEBUG_DEFAULT_ORDER_OF_OPERATIONS}
else
  declare -x DEFAULT_ORDER_OF_OPERATIONS=${NORMAL_ORDER_OF_OPERATIONS}
fi

## @fn WaitForPrerequisites()
##
WaitForPrerequisites() {
  local nodes
  local retries

  if [ ! -d "${REQUIREMENTS}" ] ; then
    Verbose "  Note: This node has no prerequisites."
    return
  fi

  nodes=$(echo $(ls ${REQUIREMENTS}))
  for _n in ${nodes}
  do
    Verbose " ${_n}"
    local required=$(ls ${REQUIREMENTS}/${_n})
    local req_cmds=""
    for _l in ${required}
    do
      if [ -x "${REQUIREMENTS}/${_n}/${_l}" ] ; then
        req_cmds="${req_cmds} ${_l}"
      fi
    done
    for _l in ${req_cmds}
    do
      local tstamp=`date +%Y.%m.%d.%H:%M`
      declare -i retries
      local rc
      local _e
      workdir=${REQUIREMENTS}/${_n}
      exe=${REQUIREMENTS}/${_n}/${_l}
      out=${TMP}/req.${_l}.${tstamp}.out
      _e=$(basename ${exe})
      Verbose "  ${_e} "
      retries=0
      rc=${EX_TEMPFAIL}
      local pwd=$(pwd)
      until (( ${retries} > ${REQUIREMENT_RETRY_LIMIT} )) || (( ${EX_OK} == ${rc} ))
      do
        cd ${workdir} || ErrExit ${EX_OSERR} "cd ${workdir}"
        ${exe} ${out} "${retries}/${REQUIREMENT_RETRY_LIMIT}"
        rc=$?
        (( ++retries ))
        sleep ${REQUIREMENT_RETRY_SLEEP}
      done
      cd ${pwd} || ErrExit ${EX_OSERR} "cd ${pwd}"
      if [ ${rc} -ne 0 ] ; then
        if [ -n "${HALT_PREREQ_ERROR}" ] ; then
          shutdown -h -P --no-wall +0
        fi
        ErrExit ${EX_OSFILE} "Node ${_n} failed ${_l}, retries=${retries}, rc=${rc}.   Connectivity or firewall issue between ${_n} and ${HOSTNAME}?"
      fi
    done
  done
  return
}

## @fn DebugNote()
##
DebugNote() {
  Verbose "DEBUG "
  return
}

## @fn VerbosePWD()
##
VerbosePWD() {
  Verbose "${ORIGPWD} "
  return
}

## @fn GetOSVersion()
## Collect OS release tags and normalize to RHEL or SLES
## @param /etc/os-release/
## @return void
## \callgraph
## \callergraph
##
GetOSVersion() {
  local f

  for f in /etc/os-release-upstream /etc/os-release  /etc/system-release
  do
    if [ ! -r ${f} ] ; then
      continue
    fi
    if [ -n "${OS_VERSION}" ] ; then
      echo "${OS_VERSION}"
      return
    fi

    local v
    v=$(grep -E '^ID=' ${f} | sed 's/ID=//' | sed 's/"//g')
    case "${v}" in
      rhel|"Red Hat Enterprise Linux"*|RHEL|centos|CentOS) echo "rhel" ; return  ;;
      sles|"SUSE Linux Enterprise Server"*|SLES)           echo "sles" ; return  ;;
      *) continue ;;
    esac
  done
  return
}


## Required commands for a given environment @see VerifyEnv()
declare -A RequiredCommands
# @todo build this via introspection of ourselves
# [base] linux-distribution independent required commands
RequiredCommands[base]="awk base64 basename cat dirname echo fmt grep head hostname logger ls mkdir pkill poweroff printf ps pwd rm su sed setsid stat strings stty sum tail tar test timeout"
# [cray] Cray-specific required commands
RequiredCommands[cray]=""
# [rhel] RHEL or RHEL-alike (TOSS, CentOS, &c) required commands
RequiredCommands[rhel]=""
# [sles] SuSe required commands
RequiredCommands[sles]=""
# [slurm] Slurm dependencies - all distributions
RequiredCommands[slurm]="sacct sacctmgr scontrol sdiag sinfo sprio squeue sshare"

## @fn VerifyEnv()
## verifies that the command environment appears sane (path, etc)
## @return if sane, otherwise calls ErrExit
## \callgraph
## \callergraph
##
VerifyEnv() {
  local o
  local os=""
  local ocray=""
  local require_uid=0
  local running_uid

  ORIGPWD=$(pwd)
  os=$(GetOSVersion)

  running_uid=$(id -u)
  if [ ${require_uid} -ne ${running_uid} ] ; then
    ErrExit ${EX_NOPERM} "Insufficient permissions"
  fi

  #
  if [ "${os}" = "sles" ] ; then
    ocray="cray"
    ## CRAY_PATH for jdetach and pdsh, respectively
    export PATH=${CRAY_PATH}:${PATH}
  fi

  for o in base ${os} ${ocray}
  do
    local r
    for r in ${RequiredCommands["${o}"]}
    do
      local c
      local f
      for c in ${r}
      do
        f=$(which ${c})
        #f=$(command -v ${c}) ## @todo use bashism rather than (deprecated) which
        if [ ! -x "${f}" ] ; then
          ErrExit ${EX_SOFTWARE} "${c}: ${f} is not executable"
        fi
      done
    done
  done

  if [ -z "${PGID}" ] ; then
    export PGID=$(($(ps -o pgid= -p "$$")))
    if [ -z "${PGID}" ] ; then
      ErrExit ${EX_SOFTWARE} "empty PGID"
    fi
  fi
  IsLANL

  if [ -z "${VC}" ] ; then
    ErrExit ${EX_SOFTWARE} "VC empty"
  fi
  if [ ! -d "${VC}" ] ; then
    ErrExit ${EX_SOFTWARE} "VC:${VC} not a directory"
  fi
  local flagfile="∕vagrant:\ NOT\ MOUNTED"
  if [ -f "${VC}/${flagfile}" ] ; then
    Verbose " already provisioned? ${VC}/${flagfile} exists"
    exit ${EX_OK}
  fi

  ## This node has been restarted from a poweroff after a full provisioning?
  local vagrant_mount=$(echo $(mount | grep '/vagrant'))
  local vagrant_mount_fstyp=$(echo ${vagrant_mount} | awk '{print $5}')
  local vagrant_mount_opts=$(echo ${vagrant_mount} | awk '{print $6}' | sed 's/,/ /g' | sed 's/(//' | sed 's/)//')

  if [ ${vagrant_mount_fstyp} = "vboxsf" ] ; then
    local _o
    local ro_mount=""
    for _o in ${vagrant_mount_opts}
    do
      if [ "${_o}" = "ro" ] ; then
        ro_mount="true"
      fi
    done
    if [ -n "${ro_mount}" ] ; then
      if [ -f ${STATE_PROVISIONED}/${HOSTNAME} ] ; then
	if [ -f ${STATE_POWEROFF}/${HOSTNAME} ] ; then
          Verbose " poweroff resumption;"
        fi
        Verbose " provisioned"
        exit ${EX_OK}
      fi
    fi
  fi

  for d in ${STATE_D} ${STATE_NONEXISTENT} ${STATE_POWEROFF} ${STATE_RUNNING} ${STATE_PROVISIONED}
  do
    Rc ErrExit ${EX_SOFTWARE} "mkdir -p ${d}"
  done

  ClearNodeState all
  MarkNodeState "${STATE_RUNNING}"

  return ${EX_OK}
}

## @fn VagrantDefaultProvider
##
VagrantDefaultProvider() {
  if [ -r /.dockerenv ] ; then
    export VAGRANT_DEFAULT_PROVIDER=${VAGRANT_DEFAULT_PROVIDER:-docker}
    export DOCKER=true
  fi
  Verbose " VAGRANT_DEFAULT_PROVIDER:${VAGRANT_DEFAULT_PROVIDER}"
  return
}

## @fn ClearNodeState()
##
ClearNodeState() {
  local scope=${1:-_all_}

  if [ -z "${HOSTNAME}" ] ; then
    ErrExit ${EX_SOFTWARE} "HOSTNAME empty"
  fi
  if [ "${scope}" = "_all_" -o "${scope}" = "all" ] ; then
    scope="${STATE_D}/*"
  fi
  Rc ErrExit ${EX_SOFTWARE} "rm -f ${scope}/${HOSTNAME}"
}

## @fn MarkNodeState()
##
MarkNodeState() {
  local new_state=${1:-_unknown_node_state}

  if [ ! -d "${new_state}" ] ; then
    ErrExit ${EX_SOFTWARE} "new_state: ${new_state} not directory"
  fi
 
  Rc ErrExit ${EX_SOFTWARE} "touch ${new_state}/${HOSTNAME}"
  return
}

## @fn MarkNodeProvisioned()
## not atomic, but the running->provisioned transition is failure prone, so
## consumers expect that both may exist and know to honor PROVISIONED over RUNNING
##
MarkNodeProvisioned() {
  MarkNodeState "${STATE_PROVISIONED}"
  ClearNodeState "${STATE_RUNNING}"
  return
}

## @fn isRoot()
##
isRoot() {
  id=$(id -u)
  if [ 0 -ne "${id}" ] ; then
    ErrExit ${EX_NOPERM} "insufficient privilege"
  fi
  return
}

## @fn ConfigureLocalRepos()
##
ConfigureLocalRepos() {
  local createrepo=$(which createrepo 2>&1)
  local reposync=$(which reposync 2>&1)
  local rsync=$(which rsync 2>&1)
  local repos_size
  local numeric="^[0-9]+$"
  local _ingested_tarball=""
  local _ingested_tarball_flagfile="${COMMON}/repos/._ingested_tarball"

  if [ ! -r ${XFR}/repos.tgz ] ; then
    Verbose " ONLY_REMOTE_REPOS [${XFR}/repos.tgz unreadable or nonexistent])"
    export ONLY_REMOTE_REPOS="true"
  fi
  if [ ! -s ${XFR}/repos.tgz ] ; then
    ErrExit ${EX_CONFIG} "repos.tgz is 0 size"
  fi
  repos_size=$(du -s -m ${XFR}/repos.tgz 2>&1 | awk '{print $1}')
  if ! [[ ${repos_size} =~ ${numeric} ]] ; then
    ErrExit ${EX_CONFIG} "repos.tgz is corrupt or empty: ${repos_size}"
  fi
  if [ ${repos_size} -lt 32 ] ; then
    ErrExit ${EX_CONFIG} "repos directory size is unrealistically low (${repos_size})"
  fi

  if [ -n "${ONLY_REMOTE_REPOS}" ] ; then
    return
  fi

  # only copy the repos area into this VM if we appear to be the one with repo-related tools installed
  ## XXX key on actual per-host flag
  [ ! -x "${createrepo}" ] && return
  [ ! -x "${reposync}" ]   && return
  [ ! -x "${rsync}" ]      && return
  [ ! -b "${REPO_DISK}" ]  && return
# [ ! -b "${REPO_PART}" ]  && return
  [ -z "${REPO_MOUNT}" ]   && return

  Rc ErrExit ${EX_OSERR}  "mkdir -p ${REPO_MOUNT}  2>&1"
  Rc ErrExit ${EX_OSERR}  "mount ${REPO_MOUNT}     2>&1"

  ## XXX collect an attribute of the host from somewhere? yes, we have it in slurm.conf, but that's not (really) available yet
  houses_storage="fs$"
  if ! [[ ${HOSTNAME} =~ ${houses_storage} ]] ; then
    Verbose " HOSTNAME:${HOSTNAME} does not appear to house the repository directly, would skip repo update"
    ## return
  fi


  ## XXX where, externally, to read from -- and know that it is authoritative?
  local _enabled=""

  _enabled=$(echo $(timeout ${YUM_TIMEOUT_EARLY} ${YUM} --disablerepo=epel repoinfo local-base | grep 'Repo-status' | sed 's/Repo-status.*://'))
  if ! [[ ${_enabled} =~ *enabled* ]] ; then
    if [ ! -f ${_ingested_tarball_flagfile} ] ; then
      repos_size=$(du -s -m ${XFR}/repos.tgz | awk '{print $1}')
      repos_size=$(expr ${repos_size} / 1024)
      Verbose " ingesting repos.tgz ${repos_size}Gb "
      ## XXX nice to put out a progress bar but the way vagrant parses the output, a dot appears on separate lines, XXX send stderr via stdbuf, but not stdout?
      ## XXX Rc ErrExit ${EX_OSFILE} "cd ${COMMON}; tar -${TAR_DEBUG_ARGS}${TAR_ARGS}f ${XFR}/repos.tgz --exclude='._*' --checkpoint-action=dot --checkpoint=4096"
      Rc ErrExit ${EX_OSFILE} "cd ${COMMON}; tar -${TAR_DEBUG_ARGS}${TAR_ARGS}f ${XFR}/repos.tgz --exclude='._*'"
      _ingested_tarball=true
      touch ${_ingested_tarball_flagfile}
    fi

    if [ -r ${YUM_REPOS_D}/${YUM_CENTOS_REPO_LOCAL} ] ; then
      Verbose " + ${YUM_CENTOS_REPO_LOCAL} "
      Rc ErrExit ${EX_OSFILE} "sed -i~ -e /^enabled=0/s/=0/=1/ ${YUM_REPOS_D}/${YUM_CENTOS_REPO_LOCAL}"
      for r in $(grep baseurl ${YUM_REPOS_D}/${YUM_CENTOS_REPO_LOCAL} | sed 's/^#.*//' | sed 's/baseurl=file:\/\///')
      do
        if [ ! -d ${r}/repodata ] ; then
          Rc ErrExit ${EX_CONFIG} "export basearch=${ARCH} releasever=${YUM_CENTOS_RELEASEVER} ; createrepo ${r}"
        fi
      done
    fi

    if [ -r ${YUM_REPOS_D}/${YUM_CENTOS_REPO_REMOTE} ] ; then
      Verbose " - ${YUM_CENTOS_REPO_REMOTE} "
      Rc ErrExit ${EX_OSFILE} "sed -i~ -e /^enabled=1/s/=1/=0/ ${YUM_REPOS_D}/${YUM_CENTOS_REPO_REMOTE}"
    fi

    size=$(du -s -m ${VC_COMMON}/repos | awk 'BEGIN {total=0} {total += $1} END {print total}')
    if [ "${size}" -ne 0 ] ; then
      Verbose "   ${VC_COMMON}/repos => ${COMMON}/repos ${size}Mb "
      Rc ErrExit ${EX_SOFTWARE} "tar -cf - -C ${VC_COMMON} repos | \
                              (cd ${COMMON}; tar ${TAR_LONG_ARGS} -${TAR_DEBUG_ARGS}${TAR_ARGS}f -)"
    fi
  fi

  if [ -z "${RSYNC_CENTOS_REPO}" ] ; then
    return
  fi

  for r in os updates
  do
    local repo_url=""
    local suffix=centos/7/${r}/${ARCH}
    d=${REPOS}/${suffix}

    if [ ! -d "${d}" ] ; then
      ErrExit ${EX_OSFILE} "${d} not a directory"
    fi

    case "${PREFERRED_REPO}" in
      "rsync://"*|"http://"*|"https://"*)
          repo_url=${PREFERRED_REPO}
          ;;
      *)
          local how_many_repo=${#CENTOS_RSYNC_REPO_URL[@]}
          local rand_repo=$(( ( $RANDOM % ${how_many_repo} ) + 1 ))
          repo_url=${CENTOS_RSYNC_REPO_URL[${rand_repo}]}
      ;;
    esac

    ### XXX replace the following with reposync to not be dependent on a repository guaranteeing the rsync protocol
    ### >>> The following can be time consuming, especially if the network connection to CENTOS_RSYNC REPO_URL is slow.
    if [ -n "${repo_url}" ] ; then 
      Verbose "   ${repo_url} ${d} "
      declare -i retries=0
      rc=0 
      local _timeout=${RSYNC_TIMEOUT}
      while [ ${retries} -le ${RSYNC_RETRY_LIMIT} -a ${rc} -ne 0 ]
      do
        timeout ${RSYNC_TIMEOUT_DRYRUN} rsync --dry-run -4 -az --delete --exclude='repo*' ${repo_url}/${suffix}/ ${d} >/dev/null 2>&1
        rc=$?
        if [ ${rc} -ne ${EX_OK} ] ; then
          repo_url=${DEFAULT_PREFERRED_REPO}
        fi
        (( ++retries ))
        _timeout=$(expr ${_timeout} \* retries)
        timeout ${_timeout} rsync -4 -az --delete --exclude='repo*' --exclude='._*' ${repo_url}/${suffix}/ ${d}/ >/dev/null 2>&1
        rc=$?
      done
    fi
  done

  for r in os updates local
  do
    if [ -z "${ARCH}" ] ; then
      ErrExit ${EX_OSERR} "empty ARCH"
    fi
    local suffix=centos/7/${r}/${ARCH}
    d=${REPOS}/${suffix}
    Rc ErrExit ${EX_OSERR} "${createrepo} --update ${d}"
  done
  return
}

## @fn CopyCommonProvision()
##
CopyCommonProvision() {
  local size
  if [ -L "${VC}" ] ; then
    ErrExit ${EX_OSFILE} "${VC} is a symlink"
  fi
  size=$(du -s -m ${VC_COMMON} --exclude=repos\* | awk 'BEGIN {total=0} {total += $1} END {print total}')
  Verbose " ${size}Mb "
  Rc ErrExit ${EX_SOFTWARE} "tar -cf - -C ${VC_COMMON} provision | \
                              (cd ${COMMON}; tar ${TAR_LONG_ARGS} -${TAR_DEBUG_ARGS}${TAR_ARGS}f -)"
  # prevent easy errors such as accidental modification of the transient in-cluster fs
  Rc ErrExit ${EX_OSFILE} "chmod -R ugo-w ${COMMON}/provision"
  Rc ErrExit ${EX_OSFILE} "chmod    ugo-w ${COMMON}/home"
  return
}

## @fn SetupSecondDisk()
##
SetupSecondDisk() {

  if [ -z "${REPO_DISK}" ] ; then
    return
  fi
  if [ ! -b ${REPO_DISK} ] ; then
    return
  fi

#  Rc ErrExit ${EX_CONFIG} "yes | parted ${REPO_DISK} --align opt mklabel gpt 2>&1"
#  Rc ErrExit ${EX_CONFIG} "yes | parted ${REPO_DISK} mkpart primary 2048s 20G 2>&1"
#  Rc ErrExit ${EX_CONFIG} "mkfs.xfs -L repos ${REPO_PART} 2>&1"
#  Rc ErrExit ${EX_CONFIG} "xfs_repair ${REPO_PART} 2>&1"
#  Verbose " ${REPO_PART} ${REPO_MOUNT}"

  export REPO_MOUNT=${COMMON}/repos
  export REPO_LOCAL=${REPO_MOUNT}/local

  Rc ErrExit ${EX_CONFIG} "mkfs.xfs -L repos ${REPO_DISK} 2>&1"
  Rc ErrExit ${EX_CONFIG} "xfs_repair ${REPO_DISK} 2>&1"
  Verbose " ${REPO_DISK} ${REPO_MOUNT}"
  return
}

## @fn CopyHomeVagrant()
##
CopyHomeVagrant() {
  local size
  local msg
  if [ -L "${VC}" ] ; then
    ErrExit ${EX_OSFILE} "${VC} is a symlink"
  fi

  if [ ! -f ${HOMEVAGRANT}/HOME\ VAGRANT ] ; then
    size=$(du -s -m ${VC}/* --exclude=common/repos --exclude='repos.tgz*' | awk 'BEGIN {total=0} {total += $1} END {print total}')
    Verbose " ${size}Mb "
    Rc ErrExit ${EX_SOFTWARE} "tar -cf - -C ${VC} \
                              --exclude='common/repos' --exclude='repos.tgz*' --exclude='*.iso' --exclude='._*' . | \
                              (cd ${HOMEVAGRANT}; tar ${TAR_LONG_ARGS} -${TAR_DEBUG_ARGS}${TAR_ARGS}f -)"
    Rc ErrExit ${EX_OSFILE} "touch ${HOMEVAGRANT}/HOME\ VAGRANT; chmod 0 ${HOMEVAGRANT}/HOME\ VAGRANT"
  fi

  dirs=$(echo $(ls ${COMMON}) | grep -v ":∕home∕vagrant∕common")
  for d in ${dirs}
  do
    if [ ! -d "${COMMON}/${d}" ] ; then
      ErrExit ${EX_OSFILE} "${COMMON}/${d} is not a directory"
    fi
  done
  Rc ErrExit ${EX_OSFILE} "chown root:root ${COMMON}/tmp"
  Rc ErrExit ${EX_OSFILE} "chmod 1777 ${COMMON}/tmp"

  Rc ErrExit ${EX_OSFILE} "chown root:root ${COMMON}/etc/hosts.allow"
  return
}

## @fn LinkSlashVagrant()
## @note unused, but possibly useful in the future
##
LinkSlashVagrant() {
  if [[ `id -n -u` == "root" ]] ; then
    if [ -d "${VC}" -a ! -L "${VC}" ] ; then
      Rc ErrExit ${EX_SOFTWARE} "cd /; umount -f ${VC}; rmdir ${VC}; ln -s ${HOMEVAGRANT}"
    fi
  fi
  return
}


## @fn FlagSlashVagrant()
##
FlagSlashVagrant() {

  if [ -n "${DOCKER}" ] ; then
    return
  fi
  if [[ `id -n -u` == "root" ]] ; then
    if [ -n "${PREVENT_SLASHVAGRANT_MOUNT}" ] ; then
      local opwd=$(pwd)
      local flagfile="∕vagrant:\ NOT\ MOUNTED"
      cd /
      # 32 = (u)mount failed
      # only touch the flagfile if we haven't unmounted /vagrant
      awk '{print $5}' < /proc/self/mountinfo | grep -s "^${VC}" >/dev/null 2>&1
      if [ $? -eq ${GREP_FOUND} ] ; then
        still_in_use=$(lsof | grep -i cwd | awk '{print $9}' | grep '/' | sort | uniq | egrep '^/vagrant')
        if [ -n "${still_in_use}" ] ; then
          Verbose " /vagrant is still in use; umount skipped."
        else
          Rc ErrExit 32 "umount -f ${VC}"
          Rc ErrExit ${EX_OSFILE} "cd ${VC}; touch ${flagfile}; chmod 0 ${flagfile}"
        fi
      else
        Rc ErrExit ${EX_OSFILE} "cd ${VC}; touch ${flagfile}; chmod 0 ${flagfile}"
      fi
      cd ${opwd}
    else
      if [ -d "${VC}" -a ! -L "${VC}" ] ; then
        #XXX dev ErrExit ${EX_OSFILE} "mount -t vboxsf -o uid=1000,gid=1000 vagrant ${VC}"
        Rc ErrExit ${EX_OSFILE} "mount -r -t vboxsf vagrant ${VC}"
      fi
    fi
  fi

  # convenient short-cuts inside the cluster
  if [ ! -L /cfg ] ; then
    Rc ErrExit ${EX_OSFILE} "ln -s ${CFG_HOMEVAGRANT} /cfg"
  fi
  if [ ! -L /common ] ; then
    Rc ErrExit ${EX_OSFILE} "ln -s ${COMMON} /common"
  fi
  return
}


## @fn OverlayRootFS()
##
OverlayRootFS() {
  if [ ! -d "${ROOTFS}" ] ; then
    ErrExit ${EX_CONFIG} "${ROOTFS}: No such directory"
  fi
  Verbose " source: ${ROOTFS//\/vagrant\/}"
  Rc ErrExit ${EX_SOFTWARE} "tar -cf - -C ${ROOTFS} . | \
	                           (cd /; tar ${TAR_LONG_ARGS} -${TAR_DEBUG_ARGS}${TAR_ARGS}f -)"
  return
}

## @fn AppendFilesRootFS()
##
AppendFilesRootFS() {
  local _fs=$(echo $(find ${ROOTFS} -name *.append -o -name *.insert))
  local _f

  for _f in ${_fs}
  do
    local _base=$(echo $(basename ${_f} | sed 's/\.*[0-9]*.(append|insert)$//'))
    for _n in ${_base}
    do
      local _action=""
      local _target=""
      local _rc
      local _ifcommand
      local _where
      local _what

      ## XXX replaceifcommand,replacewhere, replacewhat *OR* appendifcommand,appendwhere, appendwhat

      if [[ ${_base} == *.append ]] ; then 
        _action="a"

      elif [[ ${_base} == *.insert ]] ; then
        _action="i"

      else
        ErrExit ${EX_CONFIG} "Unclear action: ${_f}"
      fi

      _ifcommand=$(egrep '^ifcommand:' ${_f} | sed 's/ifcommand: //')
      _where=$(egrep '^where:' ${_f} | sed 's/where: //')
      _what=$(egrep '^what:' ${_f} | sed 's/what: //')

      local _dir=$(dirname ${_f} | sed 's:\/vagrant\/common::')
      if [ -z "${_dir}" ] ; then
        ErrExit ${EX_SOFTWARE} "AppendFilesRootFS():_dir:${_dir}"
      fi
      _target=$(echo $(echo ${_dir} | sed 's/^.*rootfs//')/${_base} | sed 's/\.[0-9]\.append//' | sed 's/\.[0-9]\.insert//')

      if [ ! -f ${_target} ] ; then
        ErrExit ${EX_SOFTWARE} "${_action}($_base) _target:${_target} does not exist"
      fi 

      if [ -n "${_ifcommand}" ] ; then
        local rc
        eval ${_ifcommand} >/dev/null 2>&1
        rc=$?
        if [ ${rc} -ne ${EX_OK} ] ; then
          continue
        fi
      fi

      local _rc
      if [ -z "${VERBOSE}" ] ; then
        grep -s "${_what}" ${_target} >/dev/null 2>&1
        _rc=$?
      else
        grep "${_what}" ${_target}
        _rc=$?
      fi
      if [ ${GREP_NOTFOUND} -eq ${_rc} ] ; then
        local _hint=$(echo ${_what} | awk '{print $1}')
        Verbose " ${_n} ${_hint}"

        if [ -z "${VERBOSE}" ] ; then
          sed -i "/${_where}/${_action} ${_what}" ${_target} >/dev/null 2>&1
          _rc=$?
        else
          sed -i "/${_where}/${_action} ${_what}" ${_target}
          _rc=$?
        fi

        if [ 0 -ne ${_rc} ] ; then
          ErrExit ${EX_SOFTWARE} "${_action}($_base) sed failure: sed -i \"\/${_where}/${_action} ${_what}\" ${_target}"
        fi

      fi
    done
  done
  return
}

## @fn CreateNFSMountPoints()
##
CreateNFSMountPoints() {
  local _dev
  local _mnt
  local _fstyp
  local _options
  local _check
  local _dump

  while read _dev _mnt _fstyp _options _check _dump
  do
    if [[ ${_def} =~ ^# ]] ; then
      continue
    fi
    if [[ ${_fstyp} =~ nfs ]] ; then
      if [ ! -d ${_mnt} ] ; then
        Rc ErrExit ${EX_OSFILE} "mkdir -p ${_mnt}"
      fi
    fi
  done < /etc/exports
  return
}

## @fn InstallRPMS()
##
InstallRPMS() {
  local early=${1:-"_not_early_rpms_"}
  local which
  local timeout
  local rpms_add
  local _rpms_add
  local _r
  local _disable_localrepo_arg_

  case "${1}" in
  install|"")
	    which=install
  	    timeout=${YUM_TIMEOUT_INSTALL}
	    ;;
  early)
    	    which=early
    	    timeout=${YUM_TIMEOUT_EARLY}
          if [ -n "${YUM_LOCALREPO_DEF}" -a -n "${LOCAL_REPO_ID}" ] ; then
            if [ -f ${YUM_LOCALREPO_DEF} ] ; then
              _disable_localrepo_arg=" --disablerepo=${LOCAL_REPO_ID} "
            fi
          fi
	    ;;
  local)
	    which=local
    	    timeout=${YUM_TIMEOUT_BASE}
	    ;;
  _not_early_rpms_)
	    ErrExit ${EX_SOFTWARE} "_not_early_rpms_"
	    ;;
  *)
	    ErrExit ${EX_SOFTWARE} "${1}"
	    ;;
  esac

  ## collect list of rpms. This list may either be a string subset of rpm names, or actual rpms
  ## If it appears to be an actual RPM, we will attempt to localinstall it rather than reach out to a remote repo
  rpms_add=$(echo $(ls ${RPM}/${which}))
  _rpms_add=""
  _rpms_localinstall=""
  _rpms_msg=""
  for _r in ${rpms_add}
  do
    local nm=${_r//-[0-9].*/}
    _rpms_msg="${_rpms_msg} ${nm}"
    # if this appears to be an actual RPM, then do a localinstall
    if [[ ${_r} = *.rpm ]] ; then
      _rpms_localinstall="${_rpms_localinstall} ./${_r}"
      #XXX _rpms_localinstall="${_rpms_localinstall} \"./${_r}\"" -- if RPM contains a shell meaningful character like parentheses in perl rpms
    else
      _rpms_add="${_rpms_add} ${_r}"
    fi
  done

  Verbose "${_rpms_msg}"

  rpms_add=${_rpms_add}
  localinstall_add=${_rpms_localinstall}
  ## Attempt to do a bulk installation.
  ## @todo If that fails, proceed with each one singly to capture the failure.
  if [ -n "${localinstall_add}" ] ; then
    Rc ErrExit ${EX_IOERR} "cd ${RPM}/${which}; \
                              timeout ${timeout} ${YUM} ${_disable_localrepo_arg} --disableplugin=fastestmirror -y localinstall ${localinstall_add}"
  fi

  ## for rpms that are not local, download them for future iterations
  for r in ${rpms_add}
  do
    if [ -x $(which yumdownloader) ] ; then
      Rc ErrExit ${EX_IOERR} "timeout ${timeout} yumdownloader --resolve --destdir=${RPM}/${which} --archlist=${ARCH} \"${r}\" ; "
    else
      Rc ErrExit ${EX_IOERR} "timeout ${timeout} ${YUM} ${_disable_localrepo_arg} --downloadonly --downloaddir=${RPM}/${which} --disableplugin=fastestmirror install \"${r}\" ; "
    fi
    Rc ErrExit ${EX_IOERR} "rm -f ${RPM}/${which}/\"${r}\" ; "
  done

  if [ -n "${rpms_add}" ] ; then
    declare -i retries
    local rc
    retries=0
    rc=${EX_TEMPFAIL}
    while [ ${retries} -lt ${YUM_RETRY_LIMIT} -a ${rc} -ne ${EX_OK} ]
    do
      local _which_repos
      cd ${RPM}/${which}
      if [ -z "${_disable_localrepo_arg}" -a -f "${YUM_LOCALREPO_DEF}" -a -n "${LOCAL_REPO_ID}" ] ; then
        _which_repos="--disablerepo=\* --enablerepo=local-base,local-base-updates,${LOCAL_REPO_ID}"
      else
        _which_repos="--disablerepo=\* --enablerepo=local-base,local-base-updates"
      fi
      if [ "${retries}" -ne 0 -a "${which}" != "early" ] ; then
        _which_repos=""
      fi
      timeout ${timeout} ${YUM} --disableplugin=fastestmirror ${_which_repos} -y install ${rpms_add}
      rc=$?
      (( ++retries ))
    done
  fi
  return
}

## @fn InstallEarlyRPMS()
##
InstallEarlyRPMS() {
  InstallRPMS early $@
  return
}

## UserAdd()
##
UserAdd() {
  if [ ! -d ${USERADD} ] ; then
    ErrExit ${EX_CONFIG} "${USERADD} No such file or directory"
  fi
  cd ${USERADD} || ErrExit ${EX_OSERR} "cd ${USERADD}"
  local users_add=$(echo $(ls ${USERADD}))
  local u

  for u in ${users_add}
  do
    if [ ! -d ${USERADD}/${u} ] ; then
      ErrExit ${EX_CONFIG} "${USERADD} is not a directory"
    fi
    cd ${USERADD}/${u} || ErrExit ${EX_OSERR} "cd ${USERADD}/${u}"
    Verbose "  ${u}"
    local uid=""
    local gid=""
    local shell_arg=""
    local shell
    local shellpath
    local groups
    local group_arg
    local dir_arg
    local exists

    if [ ! -d uid ] ; then
      ErrExit ${EX_CONFIG} "user: ${u}, no uid"
    fi
    uid=$(echo $(ls uid))
    if [ ! -d gid ] ; then
      ErrExit ${EX_CONFIG} "user: ${u}, no gid"
    fi
    gid=$(echo $(ls gid))

    if [ -d shell ] ; then
      shell=$(ls shell)
      shellpath=$(which $shell 2>&1)
      if [ -x "${shellpath}" ] ; then
        shell_arg="-s ${shellpath}"
      else
        Verbose "  Warning: ${shellpath} -- not executable"
      fi
    fi

    group_arg=""
    if [ -d groups ] ; then
      local ls_groups=$(echo $(ls groups))
      groups=$(echo ${ls_groups} | sed 's/ /,/g')

      if [ -n "${groups}" ] ; then 
        group_arg="-G ${groups}"
        Verbose "   + groups: ${groups}"
      fi
    fi

    dir_arg=""
    dir=""
    if [ -d ${HOME_BASEDIR} -o -d ${HOME_BASEDIR}/${u} ] ; then
      if [ -d ${HOME_BASEDIR}/${u} ] ; then
        dir_arg="-d ${HOME_BASEDIR}/${u}"
        dir=${HOME_BASEDIR}/${u}
      elif [ -d ${HOME_BASEDIR} ] ; then
        dir_arg="-b ${HOME_BASEDIR}"
        dir=${HOME_BASEDIR}/${u}
      fi
    fi

    exists=$(echo $(getent passwd ${u} 2>&1))
    if [ -z "${exists}" ] ; then
      gid_explicit=""
      if (( ${uid} != ${gid} )) ; then
        group_arg="-G ${gid}"
      else
        gid_explicit="-U"
      fi
      Rc ErrExit ${EX_OSERR} "useradd -u ${uid} ${gid_explicit} -o ${shell_arg} ${group_arg} ${dir_arg} ${u}"
    else
      if [ -n "${shell_arg}" ] ; then
        Rc ErrExit ${EX_OSERR} "chsh ${shell_arg} ${u}"
      fi
      if [ -n "${group_arg}" ] ; then
        Rc ErrExit ${EX_OSERR} "usermod ${group_arg} ${u}"
      fi
      if [[ ${dir_arg} =~ -d ]] ; then
        Rc ErrExit ${EX_OSERR} "usermod ${dir_arg} ${u}"
      fi
    fi

    if [ -d "${USERADD_PASSWD}" ] ; then
      if [ ! -f "${USERADD_PASSWD_CLEARTEXT}" -a ! -f "${USERADD_PASSWD_ENCRYPTED}" ] ; then
        Verbose "   - passwd"
        Rc ErrExit ${EX_OSERR} "passwd -d ${u} >/dev/null 2>&1"

      elif [ -f "${USERADD_PASSWD_ENCRYPTED}" -a -s "${USERADD_PASSWD_ENCRYPTED}" ] ; then
        local pw=$(echo $(cat ${USERADD_PASSWD_ENCRYPTED}))
        Rc ErrExit ${EX_OSERR} "echo \"${u}:${pw}\" | chpasswd -e"

      elif [ -f "${USERADD_PASSWD_CLEARTEXT}" -a -s "${USERADD_PASSWD_CLEARTEXT}" ] ; then
        local pw=$(echo $(cat ${USERADD_PASSWD_CLEARTEXT}))
        Verbose "   Note: setting cleartext passwd for user: ${u} (Ensure PermitEmptyPasswords is allowed in sshd_config.)"
        Rc ErrExit ${EX_OSERR} "echo \"${u}:${pw}\" | chpasswd "

      else
        ErrExit ${EX_CONFIG} "broken password config: ${USERADD}/${u}/${USERADD_PASSWD}"
      fi
    fi

    if [ -d ${USERADD}/${u}/secontext ] ; then
      local u_secontext=$(echo $(ls ${USERADD}/${u}/secontext))
      if [ -n "${u_secontext}" ] ; then
        if [ -d ${dir} ] ; then
          local fstyp=$(stat -f --format="%T" .)
          case "${fstyp}" in
          xfs|ext*|jfs|ffs|ufs|zfs)
            Rc ErrExit ${EX_OSERR} "chcon -R ${u_secontext} ${dir}"
            local u_setype=$(echo "${u_secontext}" | sed 's/:/ /g' | awk '{print $3}')
            if [ -z "${u_setype}" ] ; then
              ErrExit ${EX_CONFIG} "${u}: empty u_setype, u_secontext:${u_secontext}" 
            fi
            Rc ErrExit ${EX_OSERR} "semanage fcontext -a -t ${u_setype} ${dir}/\(/.*\)\? ;"
            ;;
          nfs)
            # silently skip
            ;;
          *)
            Verbose " unable to set secontext:${u_secontext}"
            Verbose " on dir: ${dir}, which has a file system type,"
            Verbose " fstype:${fstyp}  which does not implement secontext extended attributes."
            ;;
          esac
        fi
      fi
    fi

    if [ -d ${dir} ] ; then
      if [ ! -L ${home}/${u} ] ; then
        Rc ErrExit ${EX_OSFILE} "ln -f -s ${dir} /home/${u}"
      fi
      Rc ErrExit ${EX_OSFILE} "chown -h ${u} /home/${u} >/dev/null 2>&1"
      Rc ErrExit ${EX_OSFILE} "chown -R ${u} ${dir}     >/dev/null 2>&1"
    fi

    if [ ! -d "${ETC_SUDOERS_D}" ] ; then
      ErrExit ${EX_OSFILE} "${ETC_SUDOERS_D}: not a directory or does not exist, ${u}"
    fi
    local u_sudoers_d=${USERADD}/${u}/${SUDOERS_D}
    if [ -d "${u_sudoers_d}" ] ; then
      if [ -f "${u_sudoers_d}/${u}" ] ; then
        Rc ErrExit ${EX_OSFILE} "cp ${u_sudoers_d}/${u} ${ETC_SUDOERS_D}/${u}"
        Verbose "   + sudo"
      fi
    fi
  done

  cd ${ORIGPWD} || ErrExit ${EX_OSERR} "cd ${ORIGPWD}"
  return
}

## fn ClearSELinuxEnforce() {
##
## XXX needs much work, key from file system
##
ClearSELinuxEnforce() {
  Rc ErrExit ${EX_OSERR} "setenforce 0"
}

## @fn SetVagrantfileSyncFolderDisabled()
## XXX Vagrant v.2.2.7 fails on the sed (PROTOCOL ERROR in vboxsf file system)
##
SetVagrantfileSyncFolderDisabled() {
  grep "${HOSTNAME}.*synced_folder.*disabled: true" ${VAGRANTFILE} >/dev/null 2>&1
  if [ ${GREP_NOTFOUND} -eq $? ] ; then
    sed -i "/${HOSTNAME}.*synced_folder.*/s/\$/, disabled: true/" ${VAGRANTFILE}
    if [ $? -ne ${EX_OK} ] ; then
      ErrExit ${EX_OSFILE} "failed sed: set synced_folder disabled: true"
    fi
  fi

  return
}
 
## @fn ClearVagrantfileSyncFolderDisabled()
##
ClearVagrantfileSyncFolderDisabled() {
  sed -i "/${1:-_unknown_host_}.*synced_folder.*/s/, disabled: true//" ${VAGRANTFILE}
  if [ $? -ne ${EX_OK} ] ; then
    ErrExit ${EX_OSFILE} "failed sed: clear synced_folder disabled: true"
  fi
  return
} 

## @fn SetServices()
##
SetServices() {
  local _d
  local _on
  local _off
  local turnsvcmsg=""

  if [ -n "${DOCKER}" ] ; then
    return
  fi

  for _d in ${SERVICES_D} ${SERVICES_ON} ${SERVICES_OFF}
  do
    if [ ! -d "${_d}" ] ; then
      ErrExit ${EX_CONFIG} "${_d} is not a directory"
    fi
  done

  _on=$(echo $(ls ${SERVICES_ON} 2>&1))
  _off=$(echo $(ls ${SERVICES_OFF} 2>&1))
  for _do in on off
  do
    local _sysctl_do=""
    local _sysctl_on="start enable"
    local _sysctl_off="disable stop"
    local _which=""

    case "${_do}" in
    "on")       _sysctl_do=${_sysctl_on} ; _which=${_on}  ;;
    "off")      _sysctl_do=${_sysctl_off}; _which=${_off} ;;
    esac

    local _s
    local svcs_msg=""
    for _s in ${_which}
    do
      local _c
      if [[ ${_sysctl_do} = *"No such file or directory"* ]] ; then
        continue
      fi

      if [ -n "${DOCKER}" ] ; then
        if [[ ${_s} = *firewall* ]] ; then
          echo ${_s} DOCKER:${DOCKER} -- skipped
          continue
        fi
      fi

      svcs_msg="${svcs_msg} ${_s}"
      for _c in ${_sysctl_do}
      do
        Rc ErrExit ${EX_OSERR} "systemctl ${_c} ${_s} >/dev/null 2>&1"
      done
    done
    Verbose "  ${_do}:  ${svcs_msg}"
  done
  return
}


## @fn UpdateRPMS()
##
UpdateRPMS() {
  local repo_fstype
  if [ -n "${SKIP_UPDATERPMS}" ] ; then
    Verbose " flag set: SKIP_UPDATERPMS "
    return
  fi

  Verbose "  cache"
  Rc ErrExit ${EX_SOFTWARE} "timeout ${YUM_TIMEOUT_BASE}  ${YUM} --disableplugin=fastestmirror clean all >/dev/null 2>&1"

  repo_fstype=$(stat -f --format="%T" $(yum repoinfo local-base | grep Repo-baseurl | sed 's/Repo-baseurl.*:.*file://'))
  if [[ ${repo_fstype} =~ nfs ]] ; then
    Verbose "  updates skipped; repos are not local."
    return
  fi
  Rc ErrExit ${EX_SOFTWARE} "timeout ${YUM_TIMEOUT_EARLY} ${YUM} --disableplugin=fastestmirror makecache >/dev/null 2>&1"
 
  Verbose "  local-update"
  Rc ErrExit ${EX_IOERR} "timeout ${YUM_TIMEOUT_UPDATE} ${YUM} --disableplugin=fastestmirror -y update"

  Verbose "  update"
  if [ -d "${COMMON_REPOS}" ] ; then
    if [ -f "${YUM_LOCALREPO_DEF}" -a -n "${LOCAL_REPO_ID}" ] ; then
      Rc ErrExit ${EX_IOERR} "timeout ${YUM_TIMEOUT_UPDATE} ${YUM} --disableplugin=fastestmirror --disablerepo=\* --enablerepo=local-base,local-base-updates,${LOCAL_REPO_ID} -y update"
    else
      Rc ErrExit ${EX_IOERR} "timeout ${YUM_TIMEOUT_UPDATE} ${YUM} --disableplugin=fastestmirror --disablerepo=\* --enablerepo=local-base,local-base-updates -y update"
    fi
  fi

  return
}

declare -x PREV_TIMESTAMP=""
## @fn TimeStamp()
##
TimeStamp() {
  local timestamp
  local emit=""

  timestamp=$(echo $(date +%Y.%m.%d\ %H:%M\ %Z))
  if [ -z "${PREV_TIMESTAMP}" ] ; then
    export PREV_TIMESTAMP=${timestamp}
    emit="now: ${timestamp}"
  else
    emit="previous: ${PREV_TIMESTAMP}, current: ${timestamp}"
  fi
  Verbose " ${emit}"
  return
}

## @fn SW()
## @brief Do something with local software: build, configure, install, verify
##
SW() {
  local dowhat=${1:-_no_verb_SW_}
  local sw_packages
  local _s
  local what=""
  local where=""
  local manifest=""
  local ARCH=${ARCH:-$(uname -m)}

  case "${dowhat}" in
  build)   what=${CFG}/${HOSTNAME}/${BUILDWHAT} ; where=${BUILDWHERE} ;;
  install) what=${INSTALLWHAT} ;                                      ;;
  config)  what=${CONFIGWHAT}  ;                                      ;;
  verify)  what=${VERIFYWHAT}  ; RPMS_MANIFEST="required.services"    ;;
  *) ErrExit ${EX_SOFTWARE} "SW(): ${dowhat}"                         ;;
  esac

  [ ! -d "${what}" ] && \
    return

  # sw packages are sub-directories of ${what}
  # executable files in that directory are the steps to take to do ${what}
  # RPMS_MANIFEST contains a list of RPMS which, if present, would indicate
  # that doing ${what} is unnecessary
  sw_packages=$(echo $(ls ${what}))
  for _s in ${sw_packages}
  do
    if [[ ${_s} = ${SKIP_SW} ]] ; then
      Verbose  " "
      Verbose " ${_s}: SKIP_SW "
      continue
    fi

    case "${dowhat}" in
    build|install|config|verify)
      ### XXX if no manifest just use ${_s}
      if [ -r ${what}/${_s}/${RPMS_MANIFEST} ] ; then
        manifest=$(echo $(cat ${what}/${_s}/${RPMS_MANIFEST}))
      fi                                               ;;
    *)
      ErrExit ${EX_SOFTWARE} "SW(): ${dowhat}"         ;;
    esac

    # to verify where ${what} needs to be done, execute the ${verify} command
    # verify commands emit the string matched against the manifest list entry, if already done
    # config and verify are always done (verify=":") 
    local needTo=""
    local activePattern=""
    case "${dowhat}" in
    build)   where=${BUILDWHERE}/${_s}; verify="ls -R ${COMMON_LOCALREPO}/${ARCH}" ;;
    install) where="${what}/${_s}"; verify="rpm -q -a"                             ;;
    config)  where="${what}/${_s}"; verify=":"                                     ;;
    verify)  where="${what}/${_s}"; verify="systemctl --state=active --plain"      ;;
    *)       ErrExit ${EX_SOFTWARE} "SW(): ${dowhat}: ${_s}"                       ;;
    esac

    # walk through the manifest list, doing ${verify}
    for _m in ${manifest}
    do
      local present
      local verify_out
      local rc
      local _p
      verify_out=$(echo $(${verify}))
      _p=${activePattern:-"${_m}"}
      present=$(echo ${verify_out} | egrep "${_p}" >/dev/null 2>&1)
      rc=$?
      if (( ${GREP_FOUND} == ${rc} )) ; then
        Verbose " ${_m} "
      else
        needTo=${what}
        break;
      fi
    done

    local _msg=""
    if [ -z "${needTo}" ] ; then
      Verbose " ${_s}: [nothing needed]"
    else
      _msg=" ${_s}:  "
      sw=$(basename $_s)
      cmds=$(echo $(ls ${what}/${_s}))
      local c
      for c in ${cmds}
      do
        local tstamp
        _c=$(basename ${c})
        tstamp=`date +%Y.%m.%d.%H:%M`
        export WHERE=${where}

        workdir=${where}
        out=${TMP}/${dowhat}.${sw}.${_c}.${tstamp}.out
        exe=${what}/${_s}/${c}

        if [ ! -f "${exe}" ] ; then
          continue
        fi
  
        if [ -x "${exe}" ] ; then
          local _rc
          _msg="${_msg} ${c}"

          Rc Warn ${EX_SOFTWARE} "cd ${workdir}; bash ${exe} ${out}"
          _rc=$?
          if [ -s ${out} -a -z "${HUSH_OUTPUT}" ] ; then
              echo ' '
              echo --- ${out} ---
              cat ${out}
              echo --- ${out} ---
              echo ' '
          fi
          if [ ${EX_OK} -eq ${_rc} ] ; then
            Rc ErrExit ${EX_OSFILE} "rm -f ${out} >/dev/null 2>&1"
          else
            ErrExit ${_rc} "${exe} rc=${_rc} out=${out}"
          fi
        fi
      done
      Verbose "${_msg} "
    fi
    Verbose " "
  done
  return
}

## @fn BuildSW()
##
BuildSW(){
  local createrepo=$(which createrepo 2>&1)
  local verbose_was=""
  local d

  for d in ${LOCALREPO} ${COMMON_LOCALREPO} ${COMMON_LOCALREPO}/${ARCH}
  do
    if [ -n "${d}" ] ; then
      if [ ! -d ${d} -a ! -L ${d} ] ; then
        mkdir -p ${d}
      fi
    fi
  done

  # building sw can take time, provide additional feedback
  if [ -n "${VERBOSE}" ] ; then
    verbose_was="${VERBOSE}"
    VERBOSE="true+"
  fi

  SW build $@
  if [ ! -d "${COMMON_LOCALREPO}/repodata" -a -x "${createrepo}" ] ; then
    Verbose " createrepo COMMON_LOCALREPO:${COMMON_LOCALREPO}"
    ${createrepo} ${COMMON_LOCALREPO}
  fi
  VERBOSE="${verbose_was}"
  return
}

## @fn InstallLocalSW()
##
InstallLocalSW(){
  SW install $@
  return
}

## @fn ConfigSW()
##
ConfigSW() {
  SW config $@
  return
}

## @fn VerifySW()
##
VerifySW() {
  SW verify $@
  return
}

## @fn UserVerificationJobs()
##
UserVerificationJobs() {
  local _u_verify_d
  local u
  local tstamp=`date +%Y.%m.%d.%H:%M`

  if [ ! -d ${USERADD} ] ; then
    ErrExit ${EX_CONFIG} "${USERADD} No such file or directory"
  fi

  local users_add=$(echo $(ls ${USERADD}))

  for u in ${users_add}
  do
    if [ ! -d ${USERADD}/${u} ] ; then
      ErrExit ${EX_CONFIG} "${USERADD} is not a directory"
    fi

    _u_verify_d=${USERADD}/${u}/verify
    if [ ! -d ${_u_verify_d} ] ; then
      continue
    fi

    local _state=$(echo $(ls ${_u_verify_d}))
    local _n_states=$(echo ${_state} | awk '{print NF}')
    if [[ ${_n_states} != 1 ]] ; then
      ErrExit ${EX_CONFIG} "\n ${_u_verify_d} has multiple states:${_state} #:${_n_states}.\nThere must be only one state which initiates a verification job."
    fi

    # cluster is not in this state, skip
    if [ ! -f ${STATE_D}/${_state}/${HOSTNAME} ] ; then
      continue
    fi
    local _host_verify_d=${_u_verify_d}/${_state}/${HOSTNAME}
    # no directives for this host, skip
    if [ ! -d ${_host_verify_d} ] ; then
      continue
    fi

    cd ${_host_verify_d} || ErrExit ${EX_SOFTWARE} "cd ${_host_verify_d}"
    sw_list=$(echo $(ls ${_host_verify_d}))
    local opwd=$(pwd)
    _msg=" ${u}"

    for _s in ${sw_list}
    do
      _msg="${_msg}  ${_s}: "
      cd ${opwd}/${_s} || ErrExit ${EX_OSERR} "cd ${opwd}/${_s}"
      ### # executable files in this directory become the verification job
      ### # sbatch *.job

      for _x in *
      do
        local exe
        local _rc
        local workdir=${opwd}/${_s}

        if [ ! -f ${_x} ] ; then
          continue
        fi
        if [ ! -x ${_x} ] ; then
          continue
        fi
        out=${TMP}/userverify.${_s}.${_x}.${tstamp}.out
        _msg="${_msg} ${_x}"

        if [ "${u}" = "root" ] ; then
          Rc Warn ${EX_SOFTWARE} "cd ${workdir}; bash ${_x} ${out} "
          _rc=$?
        else
          Rc Warn ${EX_SOFTWARE} "cd ${workdir}; runuser -u ${u} -f -c \"bash ${_x} ${out}\" "
          _rc=$?
        fi

        if [ \( ${EX_OK} -ne ${_rc} \) -o \( -s "${out}" -a -z "${HUSH_OUTPUT}" \) ] ; then
          echo ' '
          echo --- ${out} ---
          cat ${out}
          echo --- ${out} ---
          echo ' '
        fi
        if [ ${EX_OK} -eq ${_rc} ] ; then
          Rc ErrExit ${EX_OSFILE} "rm -f ${out} >/dev/null 2>&1"
        else
          ClearNodeState "${STATE_PROVISIONED}"
          MarkNodeState "${STATE_RUNNING}"
          ErrExit ${_rc} "UserVerificationJobs(${_x}) failed, rc=${_rc}"
        fi
      done
      Verbose " ${_msg}"
    done
    cd ${opwd} || ErrExit ${EX_OSERR} "cd ${opwd}"
  done
  return
}

## ----  pre-main() processing ----

echo -n "Loading:"
for _l in ${SH_ENV} ${SH_HEADERS} ${SH_LIBS}
do
  _found_one=""
  for _sw in env inc lib
  do
    _f=${PROVISION_SRC_D}/${_sw}/${_l}
    if [ -r "${_f}" ] ; then
      _found_one=${_f}
      echo -n " ${_sw}/${_l}"
      source ${_f}
    fi
  done
  if [ -z "${_found_one}" ] ; then
    echo -e "$(basename $0): cannot find ${_l}"
    exit ${EX_SOFTWARE}
  fi
done
echo ''

## ----  pre-main() processing ----

main() {
  local dowhat="$*"
  if [ 0 -eq $# ] ; then
    dowhat=${DEFAULT_ORDER_OF_OPERATIONS}
  fi

  Trap

  local _m
  local _last=$(echo ${dowhat} | awk '{print $NF}')
  # _first or _second because SetFlags is first, but VERBOSE hasn't yet been set
  local _first=$(echo ${dowhat} | awk '{print $1}')
  local _second=$(echo ${dowhat} | awk '{print $2}')
  for _m in ${dowhat}
  do
    local separator=""
    if ! [[ ${_m} = ${_first} || ${_m} = ${_second} || ${_m} = ${_last} ]] ; then
      # if running manually, then our name is "provision", otherwise it is a dynamic name "vagrant-shell-..."
      if [[ ${IAM} =~ provision ]] ; then 
        separator=""
      fi
    fi
    Verbose "${_m} "
    ${_m}
    Verbose "${separator}"
  done
  Verbose "  "
  exit ${EX_OK}
}

Usage() {
  sed -n ': << /_USAGE_$/,/_USAGE_$/p' < ${IAMFULL} | \
    grep -v '_USAGE_$' | \
    sed "s/^#//"
  echo Try typing: \"${IAMFULL} Usage\"
  exit ${EX_USAGE}
}

main $*
ErrExit ${EX_SOFTWARE} "FAULTHROUGH: main"
exit ${EX_SOFTWARE}

# UNREACHED
: << _USAGE_
#
# provision - base sculpting of a generic OS image installation into a cluster node structure
# This is usually invoked by a builder mechanism, such as vagrant.
# Any arguments are interpreted as function calls which replace the DEFAULT_ORDER_OF_OPERATIONS.
# 
_USAGE_

# vim: tabstop=2 shiftwidth=2 expandtab background=dark syntax=on
