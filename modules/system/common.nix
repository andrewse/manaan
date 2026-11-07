{ pkgs, ... }:

{
  time.timeZone = "Australia/Sydney";
  i18n.defaultLocale = "en_US.UTF-8";
  console.keyMap = "us";

  # Flakes only: the system comes from flake.lock, never from a channel.
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
  nix.channel.enable = false;
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };
  nix.optimise.automatic = true;

  # Only keep the last 500MiB of systemd journal.
  services.journald.extraConfig = ''
    SystemMaxUse=500M
    SystemMaxFileSize=50M
  '';
  services.logrotate.enable = true;

  networking.nftables.enable = true;
  networking.firewall.enable = true;

  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestions.enable = true;
  };

  environment.systemPackages = with pkgs; [
    git
    htop
    libqalculate
    neovim
    ripgrep
    tmux
    wget
    unixtools.netstat
  ];
}
