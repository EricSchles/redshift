from pathlib import Path

DEF VOCAB_SIZE = 1e6
DEF TAG_SET_SIZE = 100


cdef class Index:
    cpdef set_path(self, path):
        self.path = path
        self.out_file = path.open('w')
        self.save_entries = True

    cpdef save(self):
        if self.save_entries:
            self.out_file.close()
        self.save_entries = False

    cpdef save_entry(self, int i, object feat_str, int hashed, int value):
        self.out_file.write(u'%d\t%s\t%d\t%d\n' % (i, feat_str, hashed, value))

    cpdef load(self, path):
        cdef long hashed
        cdef long value
        for line in path.open():
            fields = line.strip().split()
            i = int(fields[0])
            key = fields[1]
            hashed = int(fields[2])
            value = int(fields[3])
            self.load_entry(i, key, hashed, value)


cdef class StrIndex(Index):
    def __cinit__(self, expected_size, int i=1):
        self.table.set_empty_key(0)
        self.table.resize(expected_size)
        self.i = <int>i
        self.save_entries = False
    
    cdef unsigned long encode(self, char* feature) except 0:
        cdef int value
        cdef int hashed = 0
        MurmurHash3_x86_32(<char*>feature, len(feature), 0, &hashed)
        value = self.table[hashed]
        if value == 0:
            value = self.i
            self.table[hashed] = value
            self.i += 1
            if self.save_entries:
                self.save_entry(0, str(feature), hashed, value)
        assert value < 1000000
        return value

    cpdef load_entry(self, size_t i, object key, long hashed, long value):
        self.table[hashed] = value

    def __dealloc__(self):
        if self.save_entries:
            self.out_file.close()


cdef class FeatIndex(Index): 
    def __cinit__(self):
        cdef size_t i
        cdef dense_hash_map[long, long] *table
        self.tables = vector[dense_hash_map[long, long]]()
        self.i = 1

    cdef unsigned long encode(self, size_t* feature, size_t length, size_t i):
        cdef int value
        cdef int hashed = 0
        MurmurHash3_x86_32(feature, length * sizeof(size_t), i, &hashed)
        value = self.tables[i][hashed]
        if value == 0:
            self.tables[i][hashed] = self.i
            if self.save_entries:
                py_feat = []
                for j in range(length):
                    py_feat.append(str(feature[j]))
                self.save_entry(i, '_'.join(py_feat), hashed, self.i)
            value = self.i
            self.i += 1
        return value

    def set_n_predicates(self, int n):
        self.n = n
        self.save_entries = False
        for i in range(n):
            table = new dense_hash_map[long, long]()
            self.tables.push_back(table[0])
            self.tables[i].set_empty_key(0)
        self.count_features = False
 
    cpdef load_entry(self, size_t i, object key, long hashed, unsigned long value):
        self.tables[i][<long>hashed] = <unsigned long>value

    def __dealloc__(self):
        if self.save_entries:
            self.out_file.close()

"""
cdef class PruningFeatIndex(Index):
    def __cinit__(self):
        cdef size_t i
        cdef dense_hash_map[long, long] *table
        cdef dense_hash_map[long, long] *pruned
        self.unpruned = vector[dense_hash_map[long, long]]()
        self.tables = vector[dense_hash_map[long, long]]()
        self.freqs = dense_hash_map[long, long]()
        self.i = 1
        self.p_i = 1

    def set_n_predicates(self, int n):
        self.n = n
        self.save_entries = False
        for i in range(n):
            table = new dense_hash_map[long, long]()
            self.unpruned.push_back(table[0])
            self.unpruned[i].set_empty_key(0)
            pruned = new dense_hash_map[long, long]()
            self.tables.push_back(pruned[0])
            self.tables[i].set_empty_key(0)
        self.freqs.set_empty_key(0)
        self.count_features = False
    
    cdef unsigned long encode(self, size_t* feature, size_t length, size_t i):
        cdef int value
        cdef int hashed = 0
        MurmurHash3_x86_32(feature, length * sizeof(size_t), i, &hashed)
        if not self.count_features:
            return self.tables[i][hashed]
        value = self.unpruned[i][hashed]
        if value == 0:
            value = self.i
            self.unpruned[i][hashed] = value
            self.i += 1
        self.freqs[value] += 1
        if self.freqs[value] == self.threshold:
            self.tables[i][hashed] = self.p_i
            if self.save_entries:
                py_feat = []
                for j in range(length):
                    py_feat.append(str(feature[j]))
                self.save_entry(i, '_'.join(py_feat), hashed, self.p_i)
            self.p_i += 1
        return value

    cpdef load_entry(self, size_t i, object key, long hashed, unsigned long value):
        self.tables[i][<long>hashed] = <unsigned long>value

    def __dealloc__(self):
        if self.save_entries:
            self.out_file.close()

    def set_feat_counting(self, count_feats):
        self.count_features = count_feats

    def set_threshold(self, int threshold):
        self.threshold = threshold
"""


cdef class InstanceCounter:
    def __cinit__(self):
        self.n = 0
        self.counts_by_class = vector[dense_hash_map[long, long]]()

    cdef long add(self, size_t class_, size_t sent_id,
                  size_t* history, bint freeze_count) except 0:
        cdef long hashed = 0
        cdef dense_hash_map[long, long] *counts
        py_moves = []
        i = 0
        while history[i] != 0:
            py_moves.append(history[i])
            i += 1
        py_moves.append(sent_id)
        hashed = hash(tuple(py_moves))
        while class_ >= self.n:
            counts = new dense_hash_map[long, long]()
            self.counts_by_class.push_back(counts[0])
            self.counts_by_class[self.n].set_empty_key(0)
            self.n += 1
        assert hashed != 0
        if not freeze_count:
            self.counts_by_class[class_][hashed] += 1
            freq = self.counts_by_class[class_][hashed]
        else:
            freq = self.counts_by_class[class_][hashed]
            if freq == 0:
                freq = 1
            self.counts_by_class[class_][hashed] = -1
        return freq


_pos_idx = StrIndex(TAG_SET_SIZE)
_word_idx = StrIndex(VOCAB_SIZE, i=TAG_SET_SIZE)
_feat_idx = FeatIndex()

def init_feat_idx(int n, path):
    global _feat_idx
    _feat_idx.set_n_predicates(n)
    _feat_idx.set_path(path)

def init_word_idx(path):
    global _word_idx
    _word_idx.set_path(path)

def init_pos_idx(path):
    global _pos_idx
    _pos_idx.set_path(path)
    encode_pos('ROOT')
    encode_pos('NONE')
    encode_pos('OOB')


def load_feat_idx(n, path):
    global _feat_idx
    _feat_idx.set_n_predicates(n)
    _feat_idx.load(path)


def load_word_idx(path):
    global _word_idx
    _word_idx.load(path)

def load_pos_idx(path):
    global _pos_idx
    _pos_idx.load(path)

def set_feat_counting(bint feat_counting):
    global _feat_idx
    _feat_idx.set_feat_counting(feat_counting)

def set_feat_threshold(int threshold):
    global _feat_idx
    _feat_idx.set_threshold(threshold)

def encode_word(object word):
    global _word_idx
    cdef StrIndex idx = _word_idx
    py_word = word.encode('ascii')
    raw_word = py_word
    return idx.encode(raw_word)

def encode_pos(object pos):
    global _pos_idx
    cdef StrIndex idx = _pos_idx
    py_pos = pos.encode('ascii')
    raw_pos = py_pos
    return idx.encode(raw_pos)

cdef unsigned long encode_feat(size_t* feature, size_t length, size_t i):
    global _feat_idx
    cdef FeatIndex idx = _feat_idx
    return idx.encode(feature, length, i)

