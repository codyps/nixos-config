{ pkgs, ... }:
let
  authDir = "/var/lib/garm-cache-auth";
  renew = pkgs.writeShellScript "garm-cache-renew" ''
    set -eu
    cd ${authDir}
    if ! ${pkgs.openssl}/bin/openssl x509 -checkend 2592000 -noout -in tls.crt >/dev/null 2>&1; then
      ${pkgs.openssl}/bin/openssl req -new -newkey rsa:3072 -nodes \
        -keyout tls.key.next -out tls.csr -subj /CN=warbler-build-cache \
        -addext 'subjectAltName=IP:10.77.0.1' \
        -addext 'basicConstraints=critical,CA:FALSE' \
        -addext 'keyUsage=critical,digitalSignature,keyEncipherment' \
        -addext 'extendedKeyUsage=serverAuth'
      ${pkgs.openssl}/bin/openssl x509 -req -in tls.csr -CA server.crt -CAkey server.key \
        -CAcreateserial -days 90 -copy_extensions copy -out tls.crt.next
      chmod 0644 tls.crt.next
      chmod 0640 tls.key.next
      mv tls.key.next tls.key
      mv tls.crt.next tls.crt
      rm tls.csr
    fi
  '';
  status = pkgs.writeShellScript "garm-cache-status" ''
    echo 'Bazel (zpl-comparison):'
    ${pkgs.curl}/bin/curl --fail --silent --show-error http://127.0.0.1:9980/status
    echo 'Rust (zpl):'
    ${pkgs.curl}/bin/curl --fail --silent --show-error http://127.0.0.1:9981/status
  '';
  check = pkgs.writeShellScript "garm-cache-check" ''
    exec ${pkgs.python3}/bin/python3 ${./garm-cache-check.py}
  '';
  rustProxy = ''
    auth_basic "Warbler Rust cache";
    auth_basic_user_file ${authDir}/zpl/readers.htpasswd;
    limit_except GET HEAD {
      auth_basic_user_file ${authDir}/zpl/writers.htpasswd;
    }
    proxy_request_buffering off;
    proxy_read_timeout 300s;
    proxy_send_timeout 300s;
  '';
in
{
  # Credentials are generated on the host, never embedded in the Nix store.
  systemd.services.garm-cache-auth = {
    description = "Initialize Warbler build cache credentials";
    before = [ "nginx.service" ];
    path = [ pkgs.openssl pkgs.apacheHttpd pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      StateDirectory = "garm-cache-auth";
      StateDirectoryMode = "0750";
      Group = "nginx";
      UMask = "0077";
    };
    script = ''
      cd ${authDir}
      for role in reader writer; do
        if [ ! -s "$role.password" ]; then
          openssl rand -hex 32 > "$role.password"
        fi
      done
      # These are random 256-bit tokens, not human passwords. SHA avoids doing
      # expensive password stretching for every small CAS request.
      htpasswd -isc readers.htpasswd reader < reader.password
      htpasswd -is readers.htpasswd writer < writer.password
      htpasswd -isc writers.htpasswd writer < writer.password
      chmod 0640 *.htpasswd
      if [ ! -s server.crt ]; then
        openssl req -x509 -newkey rsa:3072 -nodes -days 3650 \
          -keyout server.key -out server.crt \
          -subj /CN=warbler-build-cache \
          -addext 'subjectAltName=IP:10.77.0.1' \
          -addext 'basicConstraints=critical,CA:TRUE' \
          -addext 'keyUsage=critical,keyCertSign,cRLSign'
      fi
      chmod 0644 server.crt
      chmod 0600 server.key
      ${renew}
      mkdir -p zpl
      chmod 0750 zpl
      cd zpl
      for role in reader writer; do
        if [ ! -s "$role.password" ]; then
          openssl rand -hex 32 > "$role.password"
        fi
      done
      htpasswd -isc readers.htpasswd reader < reader.password
      htpasswd -is readers.htpasswd writer < writer.password
      htpasswd -isc writers.htpasswd writer < writer.password
      chmod 0640 *.htpasswd
    '';
  };

  systemd.services.garm-cache-renew = {
    description = "Renew the Warbler cache TLS leaf certificate";
    requires = [ "garm-cache-auth.service" ];
    after = [ "garm-cache-auth.service" "nginx.service" ];
    path = [ pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      Group = "nginx";
      UMask = "0077";
      ExecStart = toString renew;
      ExecStartPost = "${pkgs.systemd}/bin/systemctl reload nginx.service";
    };
  };
  systemd.timers.garm-cache-renew = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };

  systemd.services.garm-bazel-cache = {
    description = "Warbler persistent Bazel cache for zpl-comparison";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.bazel-remote}/bin/bazel-remote --dir /var/lib/garm-bazel-cache --max_size 80 --http_address 127.0.0.1:9980 --grpc_address none";
      DynamicUser = true;
      StateDirectory = "garm-bazel-cache";
      StateDirectoryMode = "0700";
      Restart = "on-failure";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      MemoryMax = "2G";
    };
  };

  # sccache uses opaque values, not Bazel ActionResult protobufs. Keep this
  # protocol adaptation in a separate backend with separate storage and auth.
  systemd.services.garm-rust-cache = {
    description = "Warbler persistent sccache storage for zpl";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.bazel-remote}/bin/bazel-remote --dir /var/lib/garm-rust-cache --max_size 20 --http_address 127.0.0.1:9981 --grpc_address none --disable_http_ac_validation";
      DynamicUser = true;
      StateDirectory = "garm-rust-cache";
      StateDirectoryMode = "0700";
      Restart = "on-failure";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      MemoryMax = "1G";
    };
  };

  systemd.services.nginx = {
    requires = [ "garm-cache-auth.service" ];
    after = [ "garm-cache-auth.service" ];
  };
  services.nginx.virtualHosts.garm-cache = {
    onlySSL = true;
    listen = [{ addr = "10.77.0.1"; port = 9443; ssl = true; }];
    sslCertificate = "${authDir}/tls.crt";
    sslCertificateKey = "${authDir}/tls.key";
    extraConfig = ''
      client_max_body_size 2g;
    '';
    locations = {
      "/".return = "404";
      # OpenDAL probes parent collections before PUT. These are virtual paths:
      # this response exposes no data and creates no state. Object requests
      # below still require authentication and enforce the writer credential.
      "~ ^/zpl/(sccache/([0-9a-f]/)*)?$".extraConfig = ''
        default_type application/xml;
        if ($request_method = PROPFIND) {
          return 207 '<d:multistatus xmlns:d="DAV:"><d:response><d:href>/</d:href><d:propstat><d:prop><d:getlastmodified>Thu, 01 Jan 1970 00:00:00 GMT</d:getlastmodified><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>';
        }
        return 404;
      '';
      "~ ^/zpl/sccache/[0-9a-f]/[0-9a-f]/[0-9a-f]/(?<sccache_key>[0-9a-f]+)$" = {
        proxyPass = "http://127.0.0.1:9981/ac/$sccache_key";
        extraConfig = rustProxy;
      };
      "= /zpl/sccache/.sccache_check" = {
        proxyPass = "http://127.0.0.1:9981/ac/0000000000000000000000000000000000000000000000000000000000000000";
        extraConfig = rustProxy;
      };
      # One repository per backend: URL instance names alone do not isolate CAS.
      "~ ^/zpl-comparison/(ac|cas)/[0-9a-f]+$" = {
        proxyPass = "http://127.0.0.1:9980";
        extraConfig = ''
          auth_basic "Warbler build cache";
          auth_basic_user_file ${authDir}/readers.htpasswd;
          limit_except GET HEAD {
            auth_basic_user_file ${authDir}/writers.htpasswd;
          }
          proxy_request_buffering off;
          proxy_read_timeout 300s;
          proxy_send_timeout 300s;
        '';
      };
    };
  };
  programs.adminCommands.commands.garm-cache-status = [ (toString status) ];
  programs.adminCommands.commands.garm-cache-check = [ (toString check) ];
}
