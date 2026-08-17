# SSH source dependencies

The Xcode project compiles these repositories directly from source:

- `libssh`: `libssh-0.12.0` (`50313883`)
- `mbedtls`: `mbedtls-3.6.7` (`068ff080`)

Clone them with:

```sh
git submodule update --init --recursive
```

`apple-config` contains generated Apple-platform configuration headers. The
upstream submodules are left unmodified. The Xcode targets use Mbed TLS as the
libssh crypto backend and enable pthread locking. Server, SFTP, GSSAPI, FIDO2,
process execution, PCAP, and zlib support are currently disabled because the
app only needs an SSH client and `direct-tcpip` forwarding.

libssh opens the SSH forwarding channel with `ssh_channel_open_forward()`. It
does not implement the local listener and byte pump performed by OpenSSH's
`ssh -L`; that application-level tunnel code belongs in the Objective-C++/C++
layer.
