#!/bin/zsh
# Script for setting up a conda environment with for launching servers
# It sidesteps system-wide installations by relying on conda for most packages
# and by building openssl from source
# TODO: only got it to work with a static build of OpenSSL, which is not ideal
# get the directory of this script, and go one up to get the root directory
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
DIR="$(dirname "$DIR")"

# define colors for output
COLOR_GREEN='\033[0;32m'
COLOR_NC='\033[0m'
COLOR_RED='\033[0;31m'

# currently can only build in TIR without extensions
# seems un-important, as it only affects BLOOM/NEOX
ENV_NAME=tgi-env
BUILD_EXTENSIONS=false
BUILD_VLLM=true
BUILD_FLASHATTN=true
TEST_EXTRA=true
BENCHMARK=false
SERVER_WAIT=180
N_THREADS=4

# Parse command line arguments
while (( "$#" )); do
  case "$1" in
    --env-name)
      ENV_NAME=$2
      shift 2
      ;;
    --build-extensions)
      BUILD_EXTENSIONS=true
      shift 1
      ;;
    --light-mode)
      BUILD_VLLM=false
      BUILD_FLASHATTN=false
      shift 1
      ;;
    --no-tests)
      TEST_EXTRA=false
      shift 1
      ;;
    --benchmark)
      BENCHMARK=true
      shift 1
      ;;
    --server-wait)
      SERVER_WAIT=$2
      shift 2
      ;;
    --n-threads)
      N_THREADS=$2
      shift 2
      ;;
    --) # end argument parsing
      shift
      break
      ;;
    -*|--*=) # unsupported flags
      echo "Error: Unsupported flag $1" >&2
      exit 1
      ;;
    *) # preserve positional arguments
      PARAMS="$PARAMS $1"
      shift
      ;;
  esac
done
# set positional arguments in their proper place
eval set -- "$PARAMS"

set -eo pipefail

# check if CONDA_PREFIX is set and create environment
if [ -z "$CONDA_PREFIX" ]
then
    echo "(Mini)conda does not seem to be installed, please install it first or set CONDA_PREFIX appropriately"
    exit 1
fi
export CONDA_HOME=$CONDA_PREFIX
source ${CONDA_HOME}/etc/profile.d/conda.sh

# python can't handle this dependency madness, switch to C++
conda install -y -c conda-forge mamba
# we need to add the base path to get mamba to work inside the new environment
export PATH=${CONDA_HOME}/bin:$PATH

echo "Creating conda environment ${ENV_NAME}..."
mamba create -y -n ${ENV_NAME} python=3.9
conda activate ${ENV_NAME}

# # Install dependencies
mamba install -y -c conda-forge coreutils "gxx<12.0" 
mamba install -y -c conda-forge curl git tar
mamba install -y -c conda-forge "rust>=1.74"
mamba install -y -c conda-forge openssh 
mamba install -y -c "nvidia/label/cuda-11.8.0" cuda-toolkit
# pin pytorch due to some cuda-issue in pytorch==2.1.0 / something with vllm
mamba install -y -c pytorch -c nvidia pytorch==2.0.1 torchvision==0.15.2 torchaudio==2.0.2 pytorch-cuda=11.8 

# bring in the conda environment variables forward
# (not sure if needed, but added during debugging and kept for now)
export LD_LIBRARY_PATH=${CONDA_HOME}/envs/${ENV_NAME}/lib:$LD_LIBRARY_PATH
export PATH=${CONDA_HOME}/envs/${ENV_NAME}/bin:$PATH
export CUDA_HOME=${CONDA_HOME}/envs/${ENV_NAME}

# add protoc
export PROTOC_ZIP=protoc-21.12-linux-x86_64.zip
mkdir -p /tmp/protoc
mkdir -p ~/local/bin
mkdir -p ~/local/include
cd /tmp/protoc
curl -OL https://github.com/protocolbuffers/protobuf/releases/download/v21.12/$PROTOC_ZIP
unzip -o $PROTOC_ZIP -d ~/local/ bin/protoc
unzip -o $PROTOC_ZIP -d ~/local/ 'include/*'
cd $DIR
rm -rf /tmp/protoc
export LD_LIBRARY_PATH=~/local/lib:$LD_LIBRARY_PATH
export PATH=~/local/bin:$PATH

# download and build openssl
mkdir -p /tmp/openssl
cd /tmp/openssl
wget https://www.openssl.org/source/openssl-1.1.1l.tar.gz -O openssl.tar.gz
tar -xzf openssl.tar.gz
cd openssl-1.1.1l
./config --prefix=${DIR}/.openssl --openssldir=${DIR}/.openssl
make -j $N_THREADS
make install
cd $DIR
rm -rf /tmp/openssl
export LD_LIBRARY_PATH=${DIR}/.openssl/lib:$LD_LIBRARY_PATH
export PATH=${DIR}/.openssl/bin:$PATH

# install ninja for faster compilation of CUDA kernels and setup workdir 
pip install ninja
# export MAX_JOBS to limit ninjas parallelism
export MAX_JOBS=$N_THREADS
cd ${DIR}/server
mkdir -p workdir 
rm -rf workdir/*

# install vllm
if [ "$BUILD_VLLM" = true ] ; then
    cp Makefile-vllm workdir/Makefile
    cd workdir && sleep 1
    make install-vllm
    
    cd ${DIR}/server
    if [ "$TEST_EXTRA" = true ] ; then
        python3 vllm_testscript.py
    fi
    rm -rf workdir/*
fi

echo -e "${COLOR_GREEN}DONE INSTALLING VLLM${COLOR_NC}"

# install base package
cd ${DIR}
OPENSSL_DIR=${DIR}/.openssl \
OPENSSL_LIB_DIR=${DIR}/.openssl/lib \
OPENSSL_INCLUDE_DIR=${DIR}/.openssl/include \
BUILD_EXTENSIONS=$BUILD_EXTENSIONS \
    make install

echo -e "${COLOR_GREEN}DONE INSTALLING BASE PACKAGE${COLOR_NC}"

# install flash attention
if [ "$BUILD_FLASHATTN" = true ] ; then
    cd ${DIR}/server
    cp Makefile-flash-att workdir/Makefile
    cd workdir && sleep 1
    make install-flash-attention
    if [ "$TEST_EXTRA" = true ] ; then
        make test-flash-attention
    fi
    cd ${DIR}/server
fi

rm -rf workdir

echo -e "${COLOR_GREEN}DONE INSTALLING FLASH ATTENTION${COLOR_NC}"

# override protobuf
pip install 'protobuf<3.21'

# # install python client
cd ${DIR}/clients/python
pip install .

# run a example server
if [ "$BENCHMARK" = true ] ; then
    cd ${DIR}
    # trap signal to avoid orphan server process
    trap "trap - SIGTERM && kill -- -$$" SIGINT SIGTERM EXIT
    # launch server as background process, checking for errors
    make run-llama2-benchmark &
    # sleep to make sure server has time to boot
    sleep $SERVER_WAIT
    
    OPENSSL_DIR=${DIR}/.openssl \
    OPENSSL_LIB_DIR=${DIR}/.openssl/lib \
    OPENSSL_INCLUDE_DIR=${DIR}/.openssl/include \
        make install-benchmark
    python benchmark/dump_fast_tokenizer.py --tokenizer-name=lmsys/vicuna-7b-v1.5 --output=/tmp/vicuna-7b-v1.5/
    text-generation-benchmark --tokenizer-name=/tmp/vicuna-7b-v1.5 
fi

# set default conda environment variables
conda env config vars set LD_LIBRARY_PATH=${LD_LIBRARY_PATH}
conda env config vars set PATH=${PATH}
conda env config vars set CUDA_HOME=${CUDA_HOME}
