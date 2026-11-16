"""Convert the pinned executable's image layout to a dyld-loadable library."""
import struct


def adjust_segments(data, start, size, rebase):
    # Removing __PAGEZERO moves each dyld segment ordinal down by one. LEB
    # operands and symbol names must remain byte-identical, notably in lazy bind.
    end = start + size
    position = start
    operand_counts = ({0: 0, 1: 0, 2: 1, 3: 1, 4: 0, 5: 0, 6: 1, 7: 1, 8: 2}
                      if rebase else
                      {0: 0, 1: 0, 2: 1, 3: 0, 4: 0, 5: 0, 6: 1, 7: 1,
                       8: 1, 9: 0, 10: 1, 11: 0, 12: 2})
    while position < end:
        opcode = data[position] >> 4
        if opcode not in operand_counts:
            raise ValueError(f'Unknown dyld opcode at {position:#x}')
        if opcode == (2 if rebase else 7):
            if not 1 <= data[position] & 15 <= 4:
                raise ValueError('Invalid input segment ordinal')
            data[position] -= 1
        position += 1
        if not rebase and opcode == 4:
            position = data.index(0, position, end) + 1
        for _ in range(operand_counts[opcode]):
            while position < end and data[position] & 128:
                position += 1
            position += 1
    if position != end:
        raise ValueError('Truncated dyld operand')


def library_commands(data, commands, signature_offset):
    result = []
    saw_pagezero = False
    for block in commands:
        cmd, = struct.unpack_from('<I', block)
        if cmd == 0x19:
            name = block[8:24].rstrip(b'\0')
            if name == b'__PAGEZERO':
                saw_pagezero = True
                continue
            if name == b'__LINKEDIT':
                fileoff, = struct.unpack_from('<Q', block, 40)
                end = signature_offset - fileoff
                struct.pack_into('<Q', block, 32, (end + 16383) & ~16383)
                struct.pack_into('<Q', block, 48, end)
        elif cmd == 0xe:  # LC_LOAD_DYLINKER belongs to the process executable
            continue
        elif cmd == 0x80000028:  # replace LC_MAIN with the install name
            name = b'@rpath/AgyEngine.framework/AgyEngine\0'
            size = (24 + len(name) + 7) & ~7
            block = bytearray(struct.pack('<6I', 13, size, 24, 0, 0x10000, 0x10000)
                              + name.ljust(size - 24, b'\0'))
        elif cmd == 0x80000022:
            for index in range(4):
                start, size = struct.unpack_from('<II', block, 8 + index * 8)
                adjust_segments(data, start, size, index == 0)
        result.append(block)
    if not saw_pagezero:
        raise ValueError('Expected an executable with __PAGEZERO')
    del data[signature_offset:]
    struct.pack_into('<I', data, 12, 6)  # MH_DYLIB
    flags, = struct.unpack_from('<I', data, 24)
    struct.pack_into('<I', data, 24, flags & ~0x200000)  # MH_PIE is for MH_EXECUTE
    return result
