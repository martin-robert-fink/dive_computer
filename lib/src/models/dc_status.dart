enum DcStatus {
  success,
  done,
  unsupported,
  invalidArgs,
  nomemory,
  nodevice,
  noaccess,
  io,
  timeout,
  protocol,
  dataformat,
  cancelled;

  static DcStatus fromNative(int code) {
    return switch (code) {
      0 => DcStatus.success,
      1 => DcStatus.done,
      -1 => DcStatus.unsupported,
      -2 => DcStatus.invalidArgs,
      -3 => DcStatus.nomemory,
      -4 => DcStatus.nodevice,
      -5 => DcStatus.noaccess,
      -6 => DcStatus.io,
      -7 => DcStatus.timeout,
      -8 => DcStatus.protocol,
      -9 => DcStatus.dataformat,
      -10 => DcStatus.cancelled,
      _ => DcStatus.unsupported,
    };
  }
}
