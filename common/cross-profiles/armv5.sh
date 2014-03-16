# Cross build profile for ARM GNU EABI5 Soft Float.
 
XBPS_TARGET_ARCH="armv5tel"
XBPS_CROSS_TRIPLET="arm-linux-gnueabi"
XBPS_CFLAGS="-O2 -pipe"
XBPS_CXXFLAGS="$XBPS_CFLAGS"
XBPS_CROSS_CFLAGS="-march=armv5te -msoft-float -mfloat-abi=soft"
XBPS_CROSS_CXXFLAGS="$XBPS_CROSS_CFLAGS"
