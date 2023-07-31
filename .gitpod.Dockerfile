# You could use `gitpod/workspace-full` as well.
FROM gitpod/workspace-full

RUN env PYTHON_CONFIGURE_OPTS="--enable-shared --enable-optimizations --with-lto" pyenv install 3.8-dev && pyenv global 3.8-dev
RUN sudo ldconfig && sudo apt-get -q update && \
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq graphviz libblas-dev liblapack-dev cmake gfortran gcc g++ make libproj-dev proj-data proj-bin libgeos-dev curl
RUN curl -sSL https://pdm.fming.dev/dev/install-pdm.py | python3.8 - && \
    echo "export PATH=/workspace/.pyenv_mirror/user/current/bin:$PATH" >> $HOME/.bashrc
