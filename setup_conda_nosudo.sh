#!/bin/zsh
# Script for setting up a conda environment with for launching servers
# It sidesteps system-wide installations by relying on conda for most packages
# and by building openssl from source
# TODO: only got it to work with a static build of OpenSSL, which is not ideal
ENV_NAME=tgi-env
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
N_THREADS=8
# currently can only build in TIR with this set to false
# seems un-important, as it only affects BLOOM/NEOX
BUILD_EXTENSIONS=false
TEST_EXTRA=true

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

# remove possible extra cuda and gccs from path
# (not sure if needed, but added during debugging and kept for now)
export PATH=$(echo $PATH | tr ":" "\n" | grep -v cuda | grep -v gcc | tr "\n" ":" | sed 's/:$//g')
export LD_LIBRARY_PATH=$(echo $LD_LIBRARY_PATH | tr ":" "\n" | grep -v cuda | grep -v gcc | tr "\n" ":" | sed 's/:$//g')

# # Install dependencies and gxx
mamba install -y "gxx<12.0" -c conda-forge
mamba install -y -c conda-forge curl
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

export PATH=~/local/bin:$PATH
export LD_LIBRARY_PATH=~/local/lib:$LD_LIBRARY_PATH

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
    make install-server

# install ninja for faster compilation of CUDA kernels and setup workdir 
pip install ninja
cd ${DIR}/server
mkdir -p workdir 

# install vllm
cp Makefile-vllm workdir/Makefile
cd workdir && sleep 1
make -j $N_THREADS install-vllm
cd ${DIR}/server
if [ "$TEST_EXTRA" = true ] ; then
    # run vllm_testscript.py and check if it works
    python3 vllm_testscript.py
fi
rm -rf workdir/*

# install flash attention
cd ${DIR}/server
cp Makefile-flash-att workdir/Makefile
cd workdir && sleep 1
make -j $N_THREADS test-flash-attention
cd ${DIR}/server
rm -rf workdir

# # override protobuf
pip install 'protobuf<3.21'

# # install python client
cd ${DIR}/clients/python
pip install .

cd $DIR
make run-open-llama-3b-v2