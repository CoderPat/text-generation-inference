ENV_NAME=tgi-env-client
# get the directory of this script, and go one up to get the root directory
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
DIR="$(dirname "$DIR")"
N_THREADS=8
INSTALL_CHATUI=true

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
conda install -y -c conda-forge mamba

# install client
cd ${DIR}/clients/python
pip install .

echo $PATH
echo $LD_LIBRARY_PATH

if [ "$INSTALL_CHATUI" = true ] ; then
    # install chat-ui
    cd ${DIR}/chat-ui
    mamba install -y -c conda-forge mongodb pymongo "nodejs>=18"
    npm install
fi