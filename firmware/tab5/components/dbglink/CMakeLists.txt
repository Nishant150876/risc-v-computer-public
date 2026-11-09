# ESP-IDF component. The same sources build natively for host/tests/test_c_codec.py.
idf_component_register(SRCS "dbglink.c" "dbglink_client.c"
                       INCLUDE_DIRS "include")
