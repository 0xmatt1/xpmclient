#pragma OPENCL EXTENSION cl_khr_global_int32_base_atomics : enable


#define EVEN(x) (!(x & 0x1))
#define ODD(x)  (x & 0x1)

typedef struct {
  uint i0;
  uint i1;
  uint i2;
  uint i3;
  uint i4;
  uint i5;
  uint i6;
  uint ref;
} slot_t;

void slot_shr(slot_t *slot, uint n)
{
  slot->i0 = (slot->i0 >> n) | (slot->i1 << (32-n));
  slot->i1 = (slot->i1 >> n) | (slot->i2 << (32-n));
  slot->i2 = (slot->i2 >> n) | (slot->i3 << (32-n));
  slot->i3 = (slot->i3 >> n) | (slot->i4 << (32-n));
  slot->i4 = (slot->i4 >> n) | (slot->i5 << (32-n));
  slot->i5 = (slot->i5 >> n) | (slot->i6 << (32-n));
}

__global char *get_slot_ptr(__global char *ht, uint round, uint rowIdx, uint slotIdx)
{
#ifdef NV_L2CACHE_OPT
  const uint RowFragmentLog = 4;
  const uint SlotsInRow = 1 << RowFragmentLog;
  const uint SlotMask = (1 << RowFragmentLog) - 1;  
  return ht + ((slotIdx >> RowFragmentLog)*NR_ROWS*SLOT_LEN*SlotsInRow) + (rowIdx*SLOT_LEN*SlotsInRow) + (slotIdx & SlotMask)*SLOT_LEN;
#else
  return ht + rowIdx*NR_SLOTS*SLOT_LEN + SLOT_LEN*slotIdx;  
#endif
}

slot_t read_slot_global(__global char *p, uint round)
{
  slot_t out;
  if (UINTS_IN_XI(round) > 4) {
    uint8 x = *(__global uint8*)p;
    out.i0 = x.s0;
    out.i1 = x.s1;
    out.i2 = x.s2;
    out.i3 = x.s3;
    out.i4 = x.s4;
    out.i5 = x.s5;   
  } else if (UINTS_IN_XI(round) > 2) {
    uint4 x = *(__global uint4*)p;
    out.i0 = x.s0;
    out.i1 = x.s1;
    out.i2 = x.s2;
    out.i3 = x.s3;
  } else {
    uint2 x = *(__global uint2*)p;
    out.i0 = x.s0;
    out.i1 = x.s1;
  }
  
  return out;
}

void write_slot_global(__global char *ht, __global uint *rowCounters, slot_t in, uint round)
{
  // calculate row number
  uint rowIdx;
#if NR_ROWS_LOG == 12
 rowIdx = EVEN(round) ? in.i0 & 0xfff : ((in.i0 & 0x0f0f00) >> 8) | ((in.i0 & 0xf0000000) >> 24);
#elif NR_ROWS_LOG == 13
  rowIdx = EVEN(round) ? in.i0 & 0x1fff : ((in.i0 & 0x1f0f00) >> 8) | ((in.i0 & 0xf0000000) >> 24);  
#elif NR_ROWS_LOG == 14
  rowIdx = EVEN(round) ? in.i0 & 0x3fff : ((in.i0 & 0x3f0f00) >> 8) | ((in.i0 & 0xf0000000) >> 24);    
#elif NR_ROWS_LOG == 15
  rowIdx = EVEN(round) ? in.i0 & 0x7fff : ((in.i0 & 0x7f0f00) >> 8) | ((in.i0 & 0xf0000000) >> 24);    
#elif NR_ROWS_LOG == 16
  rowIdx = EVEN(round) ? in.i0 & 0xffff : ((in.i0 & 0xff0f00) >> 8) | ((in.i0 & 0xf0000000) >> 24);       
#else
#error "unsupported NR_ROWS_LOG"
#endif

  // calculate slot position in row
  uint slotIdx;
  uint rowOffset = BITS_PER_ROW * (rowIdx % ROWS_PER_UINT);
  slotIdx = atomic_add(rowCounters + rowIdx/ROWS_PER_UINT, 1 << rowOffset);
  slotIdx = (slotIdx >> rowOffset) & ROW_MASK;
  
  // remove padding
  slot_shr(&in, 8);
  
  // get pointer for slot write
  __global char *out = get_slot_ptr(ht, round, rowIdx, slotIdx);
  
  // store data
  if (round == 0) {
    uint8 x = {in.i0, in.i1, in.i2, in.i3, in.i4, in.i5, in.ref, 0}; *(__global uint8*)out = x;
  } else if (round == 1) {
    uint8 x = {in.i0, in.i1, in.i2, in.i3, in.i4, in.i5, in.ref, 0}; *(__global uint8*)out = x;
  } else if (round == 2) {
    uint8 x = {in.i0, in.i1, in.i2, in.i3, in.i4, in.ref, 0, 0}; *(__global uint8*)out = x;
  } else if (round == 3) {
    uint8 x = {in.i0, in.i1, in.i2, in.i3, in.i4, in.ref, 0, 0}; *(__global uint8*)out = x;
  } else if (round == 4) {
    uint8 x = {in.i0, in.i1, in.i2, in.i3, in.ref, 0, 0, 0}; *(__global uint8*)out = x;
  } else if (round == 5) {
    uint8 x = {in.i0, in.i1, in.i2, in.i3, in.ref, 0, 0, 0}; *(__global uint8*)out = x;
  } else if (round == 6) {
    uint4 x = {in.i0, in.i1, in.i2, in.ref}; *(__global uint4*)out = x;
  } else if (round == 7) {
    uint4 x = {in.i0, in.i1, in.ref, 0}; *(__global uint4*)out = x;
  } else if (round == 8) {
    uint2 x = {in.i0, in.ref}; *(__global uint2*)out = x;
  }
}



/*
** Assuming NR_ROWS_LOG == 16, the hash table slots have this layout (length in
** bytes in parens):
**
** round 0, table 0: cnt(4) i(4)                     pad(0)   Xi(23.0) pad(1)
** round 1, table 1: cnt(4) i(4)                     pad(0.5) Xi(20.5) pad(3)
** round 2, table 0: cnt(4) i(4) i(4)                pad(0)   Xi(18.0) pad(2)
** round 3, table 1: cnt(4) i(4) i(4)                pad(0.5) Xi(15.5) pad(4)
** round 4, table 0: cnt(4) i(4) i(4) i(4)           pad(0)   Xi(13.0) pad(3)
** round 5, table 1: cnt(4) i(4) i(4) i(4)           pad(0.5) Xi(10.5) pad(5)
** round 6, table 0: cnt(4) i(4) i(4) i(4) i(4)      pad(0)   Xi( 8.0) pad(4)
** round 7, table 1: cnt(4) i(4) i(4) i(4) i(4)      pad(0.5) Xi( 5.5) pad(6)
** round 8, table 0: cnt(4) i(4) i(4) i(4) i(4) i(4) pad(0)   Xi( 3.0) pad(5)
**
** If the first byte of Xi is 0xAB then:
** - on even rounds, 'A' is part of the colliding PREFIX, 'B' is part of Xi
** - on odd rounds, 'A' and 'B' are both part of the colliding PREFIX, but
**   'A' is considered redundant padding as it was used to compute the row #
**
** - cnt is an atomic counter keeping track of the number of used slots.
**   it is used in the first slot only; subsequent slots replace it with
**   4 padding bytes
** - i encodes either the 21-bit input value (round 0) or a reference to two
**   inputs from the previous round
**
** Formula for Xi length and pad length above:
** > for i in range(9):
** >   xi=(200-20*i-NR_ROWS_LOG)/8.; ci=8+4*((i)/2); print xi,32-ci-xi
**
** Note that the fractional .5-byte/4-bit padding following Xi for odd rounds
** is the 4 most significant bits of the last byte of Xi.
*/


__constant ulong blake_iv[] =
{
    0x6a09e667f3bcc908, 0xbb67ae8584caa73b,
    0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
    0x510e527fade682d1, 0x9b05688c2b3e6c1f,
    0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
};

/*
** Reset counters in hash table.
*/
__kernel
void kernel_init_ht(__global char *ht, __global uint *rowCounters)
{
    rowCounters[get_global_id(0)] = 0;
}


/*
** If xi0,xi1,xi2,xi3 are stored consecutively in little endian then they
** represent (hex notation, group of 5 hex digits are a group of PREFIX bits):
**   aa aa ab bb bb cc cc cd dd...  [round 0]
**         --------------------
**      ...ab bb bb cc cc cd dd...  [odd round]
**               --------------
**               ...cc cc cd dd...  [next even round]
**                        -----
** Bytes underlined are going to be stored in the slot. Preceding bytes
** (and possibly part of the underlined bytes, depending on NR_ROWS_LOG) are
** used to compute the row number.
**
** Round 0: xi0,xi1,xi2,xi3 is a 25-byte Xi (xi3: only the low byte matter)
** Round 1: xi0,xi1,xi2 is a 23-byte Xi (incl. the colliding PREFIX nibble)
** TODO: update lines below with padding nibbles
** Round 2: xi0,xi1,xi2 is a 20-byte Xi (xi2: only the low 4 bytes matter)
** Round 3: xi0,xi1,xi2 is a 17.5-byte Xi (xi2: only the low 1.5 bytes matter)
** Round 4: xi0,xi1 is a 15-byte Xi (xi1: only the low 7 bytes matter)
** Round 5: xi0,xi1 is a 12.5-byte Xi (xi1: only the low 4.5 bytes matter)
** Round 6: xi0,xi1 is a 10-byte Xi (xi1: only the low 2 bytes matter)
** Round 7: xi0 is a 7.5-byte Xi (xi0: only the low 7.5 bytes matter)
** Round 8: xi0 is a 5-byte Xi (xi0: only the low 5 bytes matter)
**
** Return 0 if successfully stored, or 1 if the row overflowed.
*/

#define mix(va, vb, vc, vd, x, y) \
    va = (va + vb + x); \
vd = rotate((vd ^ va), (ulong)64 - 32); \
vc = (vc + vd); \
vb = rotate((vb ^ vc), (ulong)64 - 24); \
va = (va + vb + y); \
vd = rotate((vd ^ va), (ulong)64 - 16); \
vc = (vc + vd); \
vb = rotate((vb ^ vc), (ulong)64 - 63);

/*
** Execute round 0 (blake).
**
** Note: making the work group size less than or equal to the wavefront size
** allows the OpenCL compiler to remove the barrier() calls, see "2.2 Local
** Memory (LDS) Optimization 2-10" in:
** http://developer.amd.com/tools-and-sdks/opencl-zone/amd-accelerated-parallel-processing-app-sdk/opencl-optimization-guide/
*/
__kernel __attribute__((reqd_work_group_size(ROUND_WORKGROUP_SIZE, 1, 1)))
void kernel_round0(__global char *ht,
                   __global uint *rowCounters,
                   __global uint *debug,
                   ulong d0,
                   ulong d1,
                   ulong d2,
                   ulong d3,
                   ulong d4,
                   ulong d5,
                   ulong d6,
                   ulong d7)
{
    uint                tid = get_global_id(0);
    ulong               v[16];
    uint                inputs_per_thread = NR_INPUTS / get_global_size(0);
    uint                input = tid * inputs_per_thread;
    uint                input_end = (tid + 1) * inputs_per_thread;
    uint                dropped = 0;
    while (input < input_end)
      {
  // shift "i" to occupy the high 32 bits of the second ulong word in the
  // message block
  ulong word1 = (ulong)input << 32;
  // init vector v
  v[0] = d0;
  v[1] = d1;
  v[2] = d2;
  v[3] = d3;
  v[4] = d4;
  v[5] = d5;
  v[6] = d6;
  v[7] = d7;
  v[8] =  blake_iv[0];
  v[9] =  blake_iv[1];
  v[10] = blake_iv[2];
  v[11] = blake_iv[3];
  v[12] = blake_iv[4];
  v[13] = blake_iv[5];
  v[14] = blake_iv[6];
  v[15] = blake_iv[7];
  // mix in length of data
  v[12] ^= ZCASH_BLOCK_HEADER_LEN + 4 /* length of "i" */;
  // last block
  v[14] ^= (ulong)-1;

  // round 1
  mix(v[0], v[4], v[8],  v[12], 0, word1);
  mix(v[1], v[5], v[9],  v[13], 0, 0);
  mix(v[2], v[6], v[10], v[14], 0, 0);
  mix(v[3], v[7], v[11], v[15], 0, 0);
  mix(v[0], v[5], v[10], v[15], 0, 0);
  mix(v[1], v[6], v[11], v[12], 0, 0);
  mix(v[2], v[7], v[8],  v[13], 0, 0);
  mix(v[3], v[4], v[9],  v[14], 0, 0);
  // round 2
  mix(v[0], v[4], v[8],  v[12], 0, 0);
  mix(v[1], v[5], v[9],  v[13], 0, 0);
  mix(v[2], v[6], v[10], v[14], 0, 0);
  mix(v[3], v[7], v[11], v[15], 0, 0);
  mix(v[0], v[5], v[10], v[15], word1, 0);
  mix(v[1], v[6], v[11], v[12], 0, 0);
  mix(v[2], v[7], v[8],  v[13], 0, 0);
  mix(v[3], v[4], v[9],  v[14], 0, 0);
  // round 3
  mix(v[0], v[4], v[8],  v[12], 0, 0);
  mix(v[1], v[5], v[9],  v[13], 0, 0);
  mix(v[2], v[6], v[10], v[14], 0, 0);
  mix(v[3], v[7], v[11], v[15], 0, 0);
  mix(v[0], v[5], v[10], v[15], 0, 0);
  mix(v[1], v[6], v[11], v[12], 0, 0);
  mix(v[2], v[7], v[8],  v[13], 0, word1);
  mix(v[3], v[4], v[9],  v[14], 0, 0);
  // round 4
  mix(v[0], v[4], v[8],  v[12], 0, 0);
  mix(v[1], v[5], v[9],  v[13], 0, word1);
  mix(v[2], v[6], v[10], v[14], 0, 0);
  mix(v[3], v[7], v[11], v[15], 0, 0);
  mix(v[0], v[5], v[10], v[15], 0, 0);
  mix(v[1], v[6], v[11], v[12], 0, 0);
  mix(v[2], v[7], v[8],  v[13], 0, 0);
  mix(v[3], v[4], v[9],  v[14], 0, 0);
  // round 5
  mix(v[0], v[4], v[8],  v[12], 0, 0);
  mix(v[1], v[5], v[9],  v[13], 0, 0);
  mix(v[2], v[6], v[10], v[14], 0, 0);
  mix(v[3], v[7], v[11], v[15], 0, 0);
  mix(v[0], v[5], v[10], v[15], 0, word1);
  mix(v[1], v[6], v[11], v[12], 0, 0);
  mix(v[2], v[7], v[8],  v[13], 0, 0);
  mix(v[3], v[4], v[9],  v[14], 0, 0);
  // round 6
  mix(v[0], v[4], v[8],  v[12], 0, 0);
  mix(v[1], v[5], v[9],  v[13], 0, 0);
  mix(v[2], v[6], v[10], v[14], 0, 0);
  mix(v[3], v[7], v[11], v[15], 0, 0);
  mix(v[0], v[5], v[10], v[15], 0, 0);
  mix(v[1], v[6], v[11], v[12], 0, 0);
  mix(v[2], v[7], v[8],  v[13], 0, 0);
  mix(v[3], v[4], v[9],  v[14], word1, 0);
  // round 7
  mix(v[0], v[4], v[8],  v[12], 0, 0);
  mix(v[1], v[5], v[9],  v[13], word1, 0);
  mix(v[2], v[6], v[10], v[14], 0, 0);
  mix(v[3], v[7], v[11], v[15], 0, 0);
  mix(v[0], v[5], v[10], v[15], 0, 0);
  mix(v[1], v[6], v[11], v[12], 0, 0);
  mix(v[2], v[7], v[8],  v[13], 0, 0);
  mix(v[3], v[4], v[9],  v[14], 0, 0);
  // round 8
  mix(v[0], v[4], v[8],  v[12], 0, 0);
  mix(v[1], v[5], v[9],  v[13], 0, 0);
  mix(v[2], v[6], v[10], v[14], 0, word1);
  mix(v[3], v[7], v[11], v[15], 0, 0);
  mix(v[0], v[5], v[10], v[15], 0, 0);
  mix(v[1], v[6], v[11], v[12], 0, 0);
  mix(v[2], v[7], v[8],  v[13], 0, 0);
  mix(v[3], v[4], v[9],  v[14], 0, 0);
  // round 9
  mix(v[0], v[4], v[8],  v[12], 0, 0);
  mix(v[1], v[5], v[9],  v[13], 0, 0);
  mix(v[2], v[6], v[10], v[14], 0, 0);
  mix(v[3], v[7], v[11], v[15], 0, 0);
  mix(v[0], v[5], v[10], v[15], 0, 0);
  mix(v[1], v[6], v[11], v[12], 0, 0);
  mix(v[2], v[7], v[8],  v[13], word1, 0);
  mix(v[3], v[4], v[9],  v[14], 0, 0);
  // round 10
  mix(v[0], v[4], v[8],  v[12], 0, 0);
  mix(v[1], v[5], v[9],  v[13], 0, 0);
  mix(v[2], v[6], v[10], v[14], 0, 0);
  mix(v[3], v[7], v[11], v[15], word1, 0);
  mix(v[0], v[5], v[10], v[15], 0, 0);
  mix(v[1], v[6], v[11], v[12], 0, 0);
  mix(v[2], v[7], v[8],  v[13], 0, 0);
  mix(v[3], v[4], v[9],  v[14], 0, 0);
  // round 11
  mix(v[0], v[4], v[8],  v[12], 0, word1);
  mix(v[1], v[5], v[9],  v[13], 0, 0);
  mix(v[2], v[6], v[10], v[14], 0, 0);
  mix(v[3], v[7], v[11], v[15], 0, 0);
  mix(v[0], v[5], v[10], v[15], 0, 0);
  mix(v[1], v[6], v[11], v[12], 0, 0);
  mix(v[2], v[7], v[8],  v[13], 0, 0);
  mix(v[3], v[4], v[9],  v[14], 0, 0);
  // round 12
  mix(v[0], v[4], v[8],  v[12], 0, 0);
  mix(v[1], v[5], v[9],  v[13], 0, 0);
  mix(v[2], v[6], v[10], v[14], 0, 0);
  mix(v[3], v[7], v[11], v[15], 0, 0);
  mix(v[0], v[5], v[10], v[15], word1, 0);
  mix(v[1], v[6], v[11], v[12], 0, 0);
  mix(v[2], v[7], v[8],  v[13], 0, 0);
  mix(v[3], v[4], v[9],  v[14], 0, 0);

  // compress v into the blake state; this produces the 50-byte hash
  // (two Xi values)
  ulong h[7];
  h[0] = d0 ^ v[0] ^ v[8];
  h[1] = d1 ^ v[1] ^ v[9];
  h[2] = d2 ^ v[2] ^ v[10];
  h[3] = d3 ^ v[3] ^ v[11];
  h[4] = d4 ^ v[4] ^ v[12];
  h[5] = d5 ^ v[5] ^ v[13];
  h[6] = (d6 ^ v[6] ^ v[14]) & 0xffff;

  // store the two Xi values in the hash table
#if ZCASH_HASH_LEN == 50
  {
    slot_t slot;
    slot.ref = input*2;
    slot.i0 = h[0];
    slot.i1 = h[0] >> 32;
    slot.i2 = h[1];
    slot.i3 = h[1] >> 32;
    slot.i4 = h[2];
    slot.i5 = h[2] >> 32;  
    slot.i6 = h[3];
    write_slot_global(ht, rowCounters, slot, 0);
  }
  
  {
    slot_t slot;
    slot.ref = input*2 + 1;
    ulong ul0 = (h[3] >> 8) | (h[4] << (64 - 8));
    ulong ul1 = (h[4] >> 8) | (h[5] << (64 - 8));
    ulong ul2 = (h[5] >> 8) | (h[6] << (64 - 8));
    ulong ul3 = (h[6] >> 8);
    slot.i0 = ul0;
    slot.i1 = ul0 >> 32;
    slot.i2 = ul1;
    slot.i3 = ul1 >> 32;
    slot.i4 = ul2;
    slot.i5 = ul2 >> 32;  
    slot.i6 = ul3;
    write_slot_global(ht, rowCounters, slot, 0);
  }

#else
#error "unsupported ZCASH_HASH_LEN"
#endif

  input++;
      }
#ifdef ENABLE_DEBUG
    debug[tid * 2] = 0;
    debug[tid * 2 + 1] = dropped;
#endif
}

#if NR_ROWS_LOG <= 14

#define ENCODE_INPUTS(row, slot0, slot1) \
    ((row << 18) | ((slot1 & 0x1ff) << 9) | (slot0 & 0x1ff))
#define DECODE_ROW(REF)   (REF >> 18)
#define DECODE_SLOT1(REF) ((REF >> 9) & 0x1ff)
#define DECODE_SLOT0(REF) (REF & 0x1ff)

#elif NR_ROWS_LOG <= 16 && NR_SLOTS <= (1 << 8)

#define ENCODE_INPUTS(row, slot0, slot1) \
    ((row << 16) | ((slot1 & 0xff) << 8) | (slot0 & 0xff))
#define DECODE_ROW(REF)   (REF >> 16)
#define DECODE_SLOT1(REF) ((REF >> 8) & 0xff)
#define DECODE_SLOT0(REF) (REF & 0xff)

#else
#error "unsupported NR_ROWS_LOG"
#endif

uint get_slots_number(__global uint *rowCounters, uint rowIdx)
{
  uint slotsInRow;
  slotsInRow = (rowCounters[rowIdx/ROWS_PER_UINT] >> (BITS_PER_ROW*(rowIdx%ROWS_PER_UINT))) & ROW_MASK;
  slotsInRow = min(slotsInRow, (uint)NR_SLOTS);
  return slotsInRow;
}

/*
** Execute one Equihash round. Read from ht_src, XOR colliding pairs of Xi,
** store them in ht_dst.
*/
void equihash_round(uint round,
                    __global char *ht_src,
                    __global char *ht_dst,
                    __global uint *debug,
                    __local uint *collisionsData,
                    __local uint *collisionsNum,
                    __local uint *slots,
                    __global uint *rowCountersSrc,
                    __global uint *rowCountersDst)
{
  uint rowIdx = get_group_id(0);
  uint localTid = get_local_id(0);
  __local uint slotCountersData[COLLISION_PER_ROW];
  __local ushort slotsData[COLLISION_PER_ROW*COLLISION_BUFFER_SIZE];
    
  __global char *p;
  uint mask;
  uint mask2;
  uint shift;
  uint shift2;
  uint    i, j;
  // NR_SLOTS is already oversized (by a factor of OVERHEAD), but we want to
  // make it even larger
  uint    n;
  uint    dropped_coll = 0;
  uint    dropped_stor = 0;
  __global ulong  *a, *b;
  // read first words of Xi from the previous (round - 1) hash table
  // the mask is also computed to read data from the previous round
#if NR_ROWS_LOG == 12
  mask = ((!(round % 2)) ? 0xf0000 : 0xf000);
  shift = ((!(round % 2)) ? 16 : 12);  
  mask2 = ((!(round % 2)) ? 0xf000: 0x00f0);
  shift2 = ((!(round % 2)) ? 8 : 0);    
#elif NR_ROWS_LOG == 13
  mask = ((!(round % 2)) ? 0xf0000 : 0xf000);
  shift = ((!(round % 2)) ? 16 : 12);  
  mask2 = ((!(round % 2)) ? 0xe000: 0x00e0);
  shift2 = ((!(round % 2)) ? 9 : 1);  
#elif NR_ROWS_LOG == 14
  mask = ((!(round % 2)) ? 0xf0000 : 0xf000);
  shift = ((!(round % 2)) ? 16 : 12);  
  mask2 = ((!(round % 2)) ? 0xc000: 0x00c0);
  shift2 = ((!(round % 2)) ? 10 : 2);
#elif NR_ROWS_LOG == 15
  mask = ((!(round % 2)) ? 0xf0000 : 0xf000);
  shift = ((!(round % 2)) ? 16 : 12);  
  mask2 = ((!(round % 2)) ? 0x8000: 0x0080);
  shift2 = ((!(round % 2)) ? 11 : 3);
#elif NR_ROWS_LOG == 16
  mask = ((!(round % 2)) ? 0xf0000 : 0xf000);
  shift = ((!(round % 2)) ? 16 : 12);  
  mask2 = 0;
  shift2 = 0;
#else
#error "unsupported NR_ROWS_LOG"
#endif    

  uint slotsInRow = get_slots_number(rowCountersSrc, rowIdx);
  
  *collisionsNum = 0;
  for (i = get_local_id(0); i < COLLISION_PER_ROW; i += get_local_size(0))
    slotCountersData[i] = 0;
  barrier(CLK_LOCAL_MEM_FENCE);
    
  for (i = localTid; i < slotsInRow; i += ROUND_WORKGROUP_SIZE) {
    p = get_slot_ptr(ht_src, round-1, rowIdx, i);
    uint xi0 = *(__global uint *)p;
    uint x = ((xi0 & mask) >> shift) |
             ((xi0 & mask2) >> shift2);
    uint slotIdx = atomic_inc(&slotCountersData[x]);
    slotIdx = min(slotIdx, COLLISION_BUFFER_SIZE-1);
    slotsData[COLLISION_BUFFER_SIZE*x+slotIdx] = i;
  }
    
  barrier(CLK_LOCAL_MEM_FENCE);
  for (uint i = localTid; i < NR_SLOTS; i += ROUND_WORKGROUP_SIZE) {
    uint xi0, xi1, xi2, xi3, xi4, xi5;
    p = get_slot_ptr(ht_src, round-1, rowIdx, i);
    
  }
  
  const uint ct_groupsize = max(1u, ROUND_WORKGROUP_SIZE / COLLISION_PER_ROW);
  for (uint collTypeIdx = localTid / ct_groupsize; collTypeIdx < COLLISION_PER_ROW; collTypeIdx += ROUND_WORKGROUP_SIZE / ct_groupsize) {
    const uint N = min((uint)slotCountersData[collTypeIdx], COLLISION_BUFFER_SIZE);
    for (uint i = 0; i < N; i++) {
      uint collision = slotsData[COLLISION_BUFFER_SIZE*collTypeIdx+i] << 12;
      for (uint j = i + 1 + localTid % ct_groupsize; j < N; j += ct_groupsize) {
        uint index = atomic_inc(collisionsNum);
        index = min(index, (uint)(LDS_COLL_SIZE-1));
        collisionsData[index] = collision | slotsData[COLLISION_BUFFER_SIZE*collTypeIdx+j];
      }
    }
  }

  barrier(CLK_LOCAL_MEM_FENCE);
  uint totalCollisions = *collisionsNum;
  totalCollisions = min(totalCollisions, (uint)LDS_COLL_SIZE);
  
  for (uint index = get_local_id(0); index < totalCollisions; index += ROUND_WORKGROUP_SIZE) {
    uint data = collisionsData[index];
    uint i = (data >> 12) & 0xFFF;
    uint j = data & 0xFFF;
    
    // load data
    slot_t s1 = read_slot_global(get_slot_ptr(ht_src, round-1, rowIdx, i), round-1);
    slot_t s2 = read_slot_global(get_slot_ptr(ht_src, round-1, rowIdx, j), round-1);
    
    // xor data and remove padding on even rounds
    s1.i0 ^= s2.i0;
    s1.i1 ^= s2.i1;
    s1.i2 ^= s2.i2;
    s1.i3 ^= s2.i3;
    s1.i4 ^= s2.i4;
    s1.i5 ^= s2.i5;    
    if (EVEN(round))
      slot_shr(&s1, 24);
    
    if (!s1.i0 && !s1.i1)
      continue;
    
    // store data
    s1.ref = ENCODE_INPUTS(rowIdx, i, j); 
    write_slot_global(ht_dst, rowCountersDst, s1, round);
  }
      
#ifdef ENABLE_DEBUG
    debug[rowIdx * 2] = dropped_coll;
    debug[rowIdx * 2 + 1] = dropped_stor;
#endif
}

/*
** This defines kernel_round1, kernel_round2, ..., kernel_round7.
*/
#define KERNEL_ROUND(N) \
__kernel __attribute__((reqd_work_group_size(ROUND_WORKGROUP_SIZE, 1, 1))) \
void kernel_round ## N(__global char *ht_src, __global char *ht_dst, \
  __global uint *rowCountersSrc, __global uint *rowCountersDst, \
        __global uint *debug) \
{ \
    __local uint slots[UINTS_IN_XI(N) * NR_SLOTS]; \
    __local uint    collisionsData[LDS_COLL_SIZE]; \
    __local uint    collisionsNum; \
    equihash_round(N, ht_src, ht_dst, debug, collisionsData, &collisionsNum, slots, rowCountersSrc, rowCountersDst); \
}
KERNEL_ROUND(1)
KERNEL_ROUND(2)
KERNEL_ROUND(3)
KERNEL_ROUND(4)
KERNEL_ROUND(5)
KERNEL_ROUND(6)
KERNEL_ROUND(7)

// kernel_round8 takes an extra argument, "sols"
__kernel __attribute__((reqd_work_group_size(ROUND_WORKGROUP_SIZE, 1, 1)))
void kernel_round8(__global char *ht_src, __global char *ht_dst,
  __global uint *rowCountersSrc, __global uint *rowCountersDst,
  __global uint *debug, __global sols_t *sols)
{
    uint    tid = get_global_id(0);
    __local uint  collisionsData[LDS_COLL_SIZE];
    __local uint  collisionsNum;
    __local uint slots[UINTS_IN_XI(8) * NR_SLOTS];
    equihash_round(8, ht_src, ht_dst, debug, collisionsData, &collisionsNum, slots, rowCountersSrc, rowCountersDst);
    if (!tid)
  sols->nr = sols->likely_invalids = 0;
}

uint expand_ref(__global char *ht, uint round, uint row, uint slot)
{
  return *(__global uint*)(get_slot_ptr(ht, round, row, slot) + 4*UINTS_IN_XI(round));
}

/*
** Expand references to inputs. Return 1 if so far the solution appears valid,
** or 0 otherwise (an invalid solution would be a solution with duplicate
** inputs, which can be detected at the last step: round == 0).
*/
uint expand_refs(uint *ins, uint nr_inputs, __global char **htabs,
  uint round)
{
//     __global char  *ht = htabs[round % 2];
    __global char *ht = htabs[round];    
    uint    i = nr_inputs - 1;
    uint    j = nr_inputs * 2 - 1;
//     uint   xi_offset = xi_offset_for_round(round);
    int     dup_to_watch = -1;
    do
      {
  ins[j] = expand_ref(ht, round,
    DECODE_ROW(ins[i]), DECODE_SLOT1(ins[i]));
  ins[j - 1] = expand_ref(ht, round,
    DECODE_ROW(ins[i]), DECODE_SLOT0(ins[i]));
  if (!round)
    {
      if (dup_to_watch == -1)
    dup_to_watch = ins[j];
      else if (ins[j] == dup_to_watch || ins[j - 1] == dup_to_watch)
    return 0;
    }
  if (!i)
      break ;
  i--;
  j -= 2;
      }
    while (1);
    return 1;
}

/*
** Verify if a potential solution is in fact valid.
*/
void potential_sol(__global char **htabs, __global sols_t *sols,
  uint ref0, uint ref1)
{
    uint  nr_values;
    uint  values_tmp[(1 << PARAM_K)];
    uint  sol_i;
    uint  i;
    nr_values = 0;
    values_tmp[nr_values++] = ref0;
    values_tmp[nr_values++] = ref1;
    uint round = PARAM_K - 1;
    do
      {
  round--;
  if (!expand_refs(values_tmp, nr_values, htabs, round))
      return ;
  nr_values *= 2;
      }
    while (round > 0);
    // solution appears valid, copy it to sols
    sol_i = atomic_inc(&sols->nr);
    if (sol_i >= MAX_SOLS)
  return ;
    for (i = 0; i < (1 << PARAM_K); i++)
  sols->values[sol_i][i] = values_tmp[i];
    sols->valid[sol_i] = 1;
}

/*
** Scan the hash tables to find Equihash solutions.
*/
__kernel __attribute__((reqd_work_group_size(SOLS_WORKGROUP_SIZE, 1, 1)))
void kernel_sols(__global char *ht0,
                 __global char *ht1,
                 __global char *ht2,
                 __global char *ht3,
                 __global char *ht4,
                 __global char *ht5,
                 __global char *ht6,
                 __global char *ht7,
                 __global char *ht8,
                 __global sols_t *sols,
                 __global uint *rowCountersSrc,
                 __global uint *rowCountersDst)
{
    __local uint refs[NR_SLOTS*SOLS_ROWS_PER_WORKGROUP];
    __local uint data[NR_SLOTS*SOLS_ROWS_PER_WORKGROUP];
    __local uint collisionsNum;
    __local ulong collisions[SOLS_THREADS_PER_ROW*4];

    uint rowIdx = get_global_id(0) / SOLS_THREADS_PER_ROW;
    uint localRowIdx = get_local_id(0) / SOLS_THREADS_PER_ROW;
    uint localTid = get_local_id(0) % SOLS_THREADS_PER_ROW;
    __local uint *refsPtr = &refs[NR_SLOTS*localRowIdx];
    __local uint *dataPtr = &data[NR_SLOTS*localRowIdx];    
    
    __global char *htabs[9] = { ht0, ht1, ht2, ht3, ht4, ht5, ht6, ht7, ht8 };
    uint    i, j;
    uint    ref_i, ref_j;
    // it's ok for the collisions array to be so small, as if it fills up
    // the potential solutions are likely invalid (many duplicate inputs)

  collisionsNum = 0;    

    uint slotsInRow = get_slots_number(rowCountersSrc, rowIdx);  

    for (i = localTid; i < slotsInRow; i += SOLS_THREADS_PER_ROW) {
      __global char *p = get_slot_ptr(htabs[PARAM_K - 1], PARAM_K-1, rowIdx, i);
      refsPtr[i] = *(__global uint *)(p + 4);
      dataPtr[i] = (*(__global uint *)p);
    }
    barrier(CLK_LOCAL_MEM_FENCE);
    
    for (i = 0; i < slotsInRow; i++)
      {
  uint a_data = dataPtr[i];
  ref_i = refsPtr[i];
  for (j = i + 1 + localTid; j < slotsInRow; j += SOLS_THREADS_PER_ROW)
    {
      if (a_data == dataPtr[j])
        {
            collisions[atomic_inc(&collisionsNum)] = ((ulong)ref_i << 32) | refsPtr[j];
          goto part2;          
        }
    }
      }

part2:  
    barrier(CLK_LOCAL_MEM_FENCE);
    uint totalCollisions = collisionsNum;
    if (get_local_id(0) < totalCollisions) {
      ulong coll = collisions[get_local_id(0)];
      potential_sol(htabs, sols, coll >> 32, coll & 0xffffffff);
    }
}
