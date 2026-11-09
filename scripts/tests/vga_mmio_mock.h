#ifndef RVC_VGA_MMIO_MOCK_H
#define RVC_VGA_MMIO_MOCK_H
#include <stdint.h>
uint32_t vga_test_read32(uint32_t address);
void vga_test_write32(uint32_t address, uint32_t value);
void vga_test_write8(uint32_t address, uint32_t value);
#define RVC_VGA_READ32(address) vga_test_read32(address)
#define RVC_VGA_WRITE32(address, value) vga_test_write32(address, value)
#define RVC_VGA_WRITE8(address, value) vga_test_write8(address, value)
#endif
