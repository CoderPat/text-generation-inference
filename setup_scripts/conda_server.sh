#!/bin/zsh
# Script for setting up a conda environment with for launching servers
# It sidesteps system-wide installations by relying on conda for most packages
# and by building openssl from source
# TODO: only got it to work with a static build of OpenSSL, which is not ideal
ENV_NAME=tgi-env-v2
# get the directory of this script, and go one up to get the root directory
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
DIR="$(dirname "$DIR")"
N_THREADS=8

# currently can only build in TIR without extensions
# seems un-important, as it only affects BLOOM/NEOX
BUILD_EXTENSIONS=false
TEST_EXTRA=true
BENCHMARK=true
SERVER_WAIT=180

set -eo pipefail

# check if CONDA_HOME is set and create environment
if [ -z "$CONDA_HOME" ]
then
    echo "Please set CONDA_HOME to the location of your conda installation"
    exit 1
fi
source ${CONDA_HOME}/etc/profile.d/conda.sh
conda create -y -n ${ENV_NAME} python=3.9
conda activate ${ENV_NAME}
# python can't handle this dependency madness, switch to C++
conda install -y -c conda-forge mamba

# check if `module` is available and unload gcc and cuda modules
if [ -x "$(command -v module)" ]
then
    # get list of loaded modules, grep for gcc and unload all gcc modules found
    # TODO: Fix this, it's not working
    # For now, unload manually
    # module list | grep gcc | sed 's/ //g' | sed 's/(gcc)//g' | xargs -I{} module unload {}
    # module unload "cuda*"
fi

# remove possible extra cuda and gccs from path
# (not sure if needed, but added during debugging and kept for now)
export PATH=$(echo $PATH | tr ":" "\n" | grep -v cuda | grep -v gcc | tr "\n" ":" | sed 's/:$//g')
export LD_LIBRARY_PATH=$(echo $LD_LIBRARY_PATH | tr ":" "\n" | grep -v cuda | grep -v gcc | tr "\n" ":" | sed 's/:$//g')

# # Install dependencies
mamba install -y "gxx<12.0" -c conda-forge
mamba install -y -c conda-forge curl git
mamba install -y -c conda-forge "rust>=1.65.0"
mamba install -y -c "nvidia/label/cuda-11.8.0" cuda-toolkit

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

# install base package
cd ${DIR}
OPENSSL_DIR=${DIR}/.openssl \
OPENSSL_LIB_DIR=${DIR}/.openssl/lib \
OPENSSL_INCLUDE_DIR=${DIR}/.openssl/include \
BUILD_EXTENSIONS=$BUILD_EXTENSIONS \
    make install

# install ninja for faster compilation of CUDA kernels and setup workdir 
pip install ninja
cd ${DIR}/server
mkdir -p workdir 

# install vllm
rm -rf workdir/*
cp Makefile-vllm workdir/Makefile
cd workdir && sleep 1
make -j $N_THREADS install-vllm
make test-vllm
cd ${DIR}/server
if [ "$TEST_EXTRA" = true ] ; then
    make test-vllm
    python3 vllm_testscript.py
fi
rm -rf workdir/*

# install flash attention
cd ${DIR}/server
cp Makefile-flash-att workdir/Makefile
cd workdir && sleep 1
make -j $N_THREADS install-flash-attention
if [ "$TEST_EXTRA" = true ] ; then
    make test-flash-attention
fi
cd ${DIR}/server
rm -rf workdir

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