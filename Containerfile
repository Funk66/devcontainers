# hadolint global ignore=DL3008
FROM ubuntu:26.04

ENV LANG=C.UTF-8 EDITOR=nvim VISUAL=nvim NVIM_DEVCONTAINER=1

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update && apt-get install -y --no-install-recommends \
  bash \
  build-essential \
  ca-certificates \
  curl \
  fd-find \
  fzf \
  git \
  git-delta \
  golang \
  gpg \
  jq \
  lazygit \
  less \
  locales \
  make \
  nodejs \
  npm \
  openssh-client \
  python3 \
  ripgrep \
  sudo \
  unzip \
  yq \
  xz-utils \
  && curl -fsSL https://get.docker.com | sh \
  && echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ubuntu \
  && chmod 0440 /etc/sudoers.d/ubuntu \
  && curl -fsSl https://cli.github.com/packages/githubcli-archive-keyring.gpg > /etc/apt/keyrings/githubcli-archive-keyring.gpg \
  && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
  && apt-get update && apt-get install -y --no-install-recommends gh \
  && rm -rf /var/lib/apt/lists/* \
  && ln -s "$(command -v fdfind)" /usr/local/bin/fd \
  && printf 'export PAGER=less\n' >> /etc/bash.bashrc \
  && printf 'set -o vi\n' >> /etc/bash.bashrc \
  && printf 'export PS1="\\[\\e[32m\\]\\w\\[\\e[33m\\]|>\\e[0m\\] "' >> /home/ubuntu/.bashrc \
  && printf 'export FZF_DEFAULT_COMMAND="fd --type f --hidden --follow --exclude .git"\n' >> /etc/bash.bashrc \
  && printf 'export FZF_CTRL_R_OPTS="--sort --scheme=history"\n' >> /etc/bash.bashrc \
  && printf 'eval "$(fzf --bash)"\n' >> /etc/bash.bashrc \
  && ssh-keyscan -t ed25519,rsa,ecdsa github.com >> /etc/ssh/ssh_known_hosts \
  && locale-gen en_US.UTF-8 \
  && update-locale LANG=en_US.UTF-8 \
  && mkdir -p /var/lib/docker \
  && groupadd -g 999 docker 2>/dev/null || true \
  && usermod -aG docker ubuntu

RUN set -eux; \
    nvim_arch="$(dpkg --print-architecture | sed -e 's/amd64/x86_64/')"; \
    curl -fsSL "https://github.com/neovim/neovim/releases/latest/download/nvim-linux-${nvim_arch}.tar.gz" -o /tmp/nvim.tar.gz; \
    mkdir -p /opt/nvim; \
    tar -xzf /tmp/nvim.tar.gz -C /opt/nvim --strip-components=1; \
    ln -s /opt/nvim/bin/nvim /usr/local/bin/nvim; \
    rm -rf /tmp/nvim.tar.gz

COPY --chown=1000:1000 dotfiles/gitconfig /home/ubuntu/.gitconfig
COPY --chown=1000:1000 dotfiles/opencode.json /home/ubuntu/.config/opencode/opencode.json

USER 1000
RUN mkdir -p ~/.local/share/nvim ~/.local/state/nvim ~/.local/state/opencode \
  && git clone --depth 1 https://github.com/funk66/vim ~/.config/nvim \
  && curl -fsSL https://opencode.ai/v2/install | bash

RUN echo "prefix = ~/.npm-packages" > ~/.npmrc
ENV NPM_CONFIG_PREFIX=/home/ubuntu/.npm-packages
ENV PATH="/home/ubuntu/.npm-packages/bin:/home/ubuntu/.opencode/bin:$PATH"

WORKDIR /home/ubuntu
CMD ["dockerd"]
