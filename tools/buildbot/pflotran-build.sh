#!/usr/bin/env bash

################################################################################
#
# Build script for the pflotran-dev buildbot system.
#
# Author: Ben Andre <bandre@lbl.gov>
#
# All the logic for buildbot is moved out of the buildbot config and
# placed here.
#
# Requirements:
#
#  - Assumes that the script is being called from the root of the
#    pflotran repo. If not, then the pflotran directory must be set on
#    the command line (-p).
#
# Builder requirements:
#
#  - git, mercurial, working mpi compilers
#
#  - a working petsc configure script that will build petsc and any
#    additional TPLs needed for that builder, i.e. hdf5, metis and
#    parmetis for unstructured mesh.
#
#  - NOTE: petsc must be built with '--with-shared-libraries=0'
#    because we check for the presence of libpetsc.a to figure out if
#    a petsc build is acceptable.
#
#
################################################################################

################################################################################
#
# Global variables
#
################################################################################
BUILDER_ID=
PFLOTRAN_DIR=`pwd`
PETSC_DIR=${PFLOTRAN_DIR}/../petsc.git
PETSC_ARCH=
BUILD_STATUS=0

################################################################################
#
# work routines
#
################################################################################

function set-builder-info() {
    BUILDER_ID=`hostname -s`
    PETSC_ARCH=${BUILDER_ID}-${COMPILER}

    echo "pflotran builder id : ${BUILDER_ID}"

}

function stage-petsc() {
    echo "PETSc stage"

    if [ -z ${PETSC_DIR} ]; then
        echo "ERROR: could not assign PETSC_DIR"
        exit 1
    fi
    if [ -z ${PETSC_ARCH} ]; then
        echo "ERROR: could not assign PETSC_ARCH"
        exit 1
    fi

    _petsc_version_file=${PFLOTRAN_DIR}/tools/buildbot/petsc/petsc-git-version.txt
    _petsc_required_version=`cat ${_petsc_version_file}`
    echo "PFLOTRAN requires PETSc git reversion ${_petsc_required_version}"

    if [ -d ${PETSC_DIR} ]; then
        echo "Found existing PETSc directory."
        cd ${PETSC_DIR}
        _petsc_install_version=`git log --pretty="%H" -1 HEAD`
        echo "Found PETSc version: ${_petsc_install_version}"
        if [ ${_petsc_install_version} != ${_petsc_required_version} ]; then
            echo "Rebuilding PETSc at version: ${_petsc_required_version}"
            petsc-build ${_petsc_required_version}
        fi
        _lib_petsc=${PETSC_DIR}/${PETSC_ARCH}/lib/libpetsc.a
        if [ ! -f ${_lib_petsc} ]; then
            echo "PETSc : could not find libpetsc.a for this PETSC_ARCH. Rebuilding."
            echo "    ${_lib_petsc}"
            petsc-build ${_petsc_required_version}
        fi
    else
        echo "Building PETSc from scratch"
        git clone https://bitbucket.org/petsc/petsc.git ${PETSC_DIR}
        cd ${PETSC_DIR}
        petsc-build ${_petsc_required_version}
    fi

}

function petsc-build() {
    git checkout $1

    _petsc_config_file="${PFLOTRAN_DIR}/tools/buildbot/petsc/configure-${PETSC_ARCH}.py"
    if [ ! -f ${_petsc_config_file} ]; then
        echo "ERROR: pflotran repository does not contain a petsc configure script for this builder. Expected: '${_petsc_config_file}'"
        exit 1
    else
        echo "Linking PETSc config file from pflotran repo: ${_petsc_config_file}"
    fi
    ln -s  ${_petsc_config_file} ${PETSC_DIR}/configure-${PETSC_ARCH}.py
    echo "Configuring PETSc..."
    python configure-${PETSC_ARCH}.py
    echo "Building PETSc..."
    make PETSC_DIR=${PETSC_DIR} PETSC_ARCH=${PETSC_ARCH} all
    echo "Testing PETSc..."
    make PETSC_DIR=${PETSC_DIR} PETSC_ARCH=${PETSC_ARCH} test
    BUILD_STATUS=$?
}

function stage-pflotran-build() {
    echo "Building PFLOTRAN with :"
    echo "  PETSC_DIR=${PETSC_DIR}"
    echo "  PETSC_ARCH=${PETSC_ARCH}"
    export PETSC_DIR PETSC_ARCH
    _pflotran_flags=
    _flags_file=${PFLOTRAN_DIR}/tools/buildbot/build-flags/${BUILD_FLAGS}.txt
    if [ -f ${_flags_file} ]; then
        _pflotran_flags=`cat ${_flags_file}`
        echo "  pflotran build flags=${_pflotran_flags}"
    else
        echo "Could not find build flags file: ${_flags_file}. Building with 'make pflotran'."
    fi
    
    cd ${PFLOTRAN_DIR}/src/pflotran
    make clean
    make ${_pflotran_flags} pflotran
    BUILD_STATUS=$?
}

function stage-pflotran-test() {
    echo "Running PFLOTRAN regression tests with:"
    echo "  PETSC_DIR=${PETSC_DIR}"
    echo "  PETSC_ARCH=${PETSC_ARCH}"
    export PETSC_DIR PETSC_ARCH
    _test_dir=${PFLOTRAN_DIR}/regression_tests
    _pflotran_flags=
    _flags_file=${PFLOTRAN_DIR}/tools/buildbot/build-flags/${BUILD_FLAGS}.txt
    if [ -f ${_flags_file} ]; then
        _pflotran_flags=`cat ${_flags_file}`
        echo "  pflotran build flags=${_pflotran_flags}"

        grep -e "makefile_new" ${_flags_file} &> /dev/null
        if [ "$?" -eq "0" ]; then
            _test_dir=${PFLOTRAN_DIR}/regression_tests_refactor
        fi
    else
        echo "Could not find build flags file: ${_flags_file}. Testing with 'make pflotran'."
    fi

    echo "  test directory : ${_test_dir}"
    cd ${_test_dir}
    make clean-tests &> /dev/null
    make test
    BUILD_STATUS=$?
    cat *.testlog
}


################################################################################
#
# main program
#
################################################################################
function usage() {
     echo "
Usage: $0 [options]
    -b BUILD_FLAGS    group of build flags to use.
    -c COMPILER       compiler name: gnu, pgi, intel
    -h                print this help message
    -p PFLOTRAN_DIR   root directory for the build (default: '.')
    -s BUILD_STAGE    build stage must be one of:
                        all petsc pflotran-build pflotran-test

Notes:

  - The build flags group must have a corresponding file in the
    tools/buildbot/build-flags/ directory.

"
}

# setup based on commandline args
BUILD_FLAGS="__NONE__"
BUILD_STAGE=
COMPILER=
while getopts "b:c:hp:s:" FLAG
do
  case ${FLAG} in
    b) BUILD_FLAGS=${OPTARG};;
    c) COMPILER=${OPTARG};;
    h) usage;;
    p) PFLOTRAN_DIR=${OPTARG};;
    s) BUILD_STAGE=${OPTARG};;
  esac
done

# verify all required info is set
if [ -z "${BUILD_STAGE}" ]; then
    echo "ERROR: The build stage name must be provided on the command line."
    exit 1
fi

if [ -z "${COMPILER}" ]; then
    echo "ERROR: The compiler name must be provided on the command line."
    exit 1
fi

set-builder-info

echo "PFLOTRAN_DIR: ${PFLOTRAN_DIR}"

case ${BUILD_STAGE} in
    all) stage-petsc; stage-pflotran-build; stage-pflotran-test;;
    petsc) stage-petsc;;
    pflotran-build) stage-pflotran-build;;
    pflotran-test) stage-pflotran-test;;
    *) echo "ERROR: The requested build stage '${BUILD_STAGE}' is invalid."; exit 1;;
esac

exit ${BUILD_STATUS}


