# 
# Copyright (c) 2020 Minato Sato
# All rights reserved.
#
# This source code is licensed under the license found in the
# LICENSE file in the root directory of this source tree.
#

# cython: language_level=3
# distutils: language=c++

import cython
import numpy as np
from scipy import sparse
from collections import Counter
from cython.parallel import prange
from sklearn import utils
from tqdm import tqdm
from cython.operator import dereference
from cython.operator import postincrement

cimport numpy as np
from cython cimport integral
from libcpp cimport bool
from libcpp.vector cimport vector
from libcpp.unordered_map cimport unordered_map

from .model cimport GloVeModel
from .optimizer cimport GloVeAdaGrad

cdef extern from "util.h" namespace "cymf" nogil:
    cdef int cpucount()

cdef inline int imax(int a, int b) nogil:
    if (a > b):
        return a
    else:
        return b

cdef inline integral iabs(integral a) nogil:
    if (a < 0):
        return -a
    else:
        return a

class GloVe(object):
    """
    GloVe: Global Vectors for Word Representation
    https://nlp.stanford.edu/projects/glove/
    
    Attributes:
        num_components (int): A dimensionality of latent vector
        learning_rate (double): A learning rate used in AdaGrad
        alpha (double): See the paper.
        x_max (double): See the paper.
        W (np.ndarray[double, ndim=2]): Word vectors
    """
    def __init__(self, int num_components = 50,
                       double learning_rate = 0.01,
                       double alpha = 0.75,
                       double x_max = 10.0):
        """
        Args:
            num_components (int): A dimensionality of latent vector
            learning_rate (double): A learning rate used in AdaGrad
            alpha (double): See the paper.
            x_max (double): See the paper.
        """
        self.num_components = num_components
        self.learning_rate = learning_rate
        self.alpha = alpha
        self.x_max = x_max
        self.W = None

    def fit(self, X, int num_epochs, int num_threads, bool verbose = False):
        """
        Training GloVe model with Gradient Descent.

        Args:
            X: A word-word cooccurrence matrix.
            num_epochs (int): A number of epochs.
            num_threads (int): A number of threads in HOGWILD! (http://i.stanford.edu/hazy/papers/hogwild-nips.pdf)
            verbose (bool): Whether to show the progress of training.
        """
        if X is None:
            raise ValueError()

        if not isinstance(X, (sparse.lil_matrix, sparse.csr_matrix, sparse.csc_matrix)):
            raise TypeError("X must be a type of scipy.sparse.*_matrix.")
                  
        self.W = np.random.uniform(low=-0.5, high=0.5, size=(X.shape[0], self.num_components)) / self.num_components
        self.bias = np.random.uniform(low=-0.5, high=0.5, size=(X.shape[0],)) / self.num_components
        _W = np.random.uniform(low=-0.5, high=0.5, size=(X.shape[1], self.num_components)) / self.num_components
        _bias = np.random.uniform(low=-0.5, high=0.5, size=(X.shape[0],)) / self.num_components

        num_threads = num_threads if num_threads > 0 else cpucount()
        central_words, context_words = X.nonzero()
        counts = X.data

        self._fit_glove(*utils.shuffle(central_words, context_words, counts),
                        self.W,
                        self.bias,
                        _W,
                        _bias,
                        num_epochs,
                        self.learning_rate,
                        self.x_max,
                        self.alpha,
                        num_threads,
                        verbose)
        
        self.W = (self.W + _W) / 2.0


    @cython.boundscheck(False)
    @cython.wraparound(False)
    def _fit_glove(self,
                   integral[:] central_words,
                   integral[:] context_words,
                   double[:] counts,
                   double[:,:] central_W,
                   double[:] central_bias,
                   double[:,:] context_W,
                   double[:] context_bias,
                   int num_epochs, 
                   double learning_rate,
                   double x_max,
                   double alpha,
                   int num_threads,
                   bool verbose):
        cdef int iterations = num_epochs
        cdef int N = central_words.shape[0]
        cdef int N_K = central_W.shape[1]
        cdef double[:] loss = np.zeros(N)
        cdef int u, i, j, k, l, iteration

        cdef double accum_loss
        
        cdef list description_list

        cdef GloVeAdaGrad optimizer
        optimizer = GloVeAdaGrad(learning_rate)
        optimizer.set_parameters(central_W, context_W, central_bias, context_bias)

        cdef GloVeModel glove_model = GloVeModel(
            central_W, context_W, central_bias, context_bias, x_max, alpha, optimizer, num_threads)

        with tqdm(total=iterations, leave=True, ncols=100, disable=not verbose) as progress:
            for iteration in range(iterations):
                accum_loss = 0.0
                for l in prange(N, nogil=True, num_threads=num_threads):
                    loss[l] = glove_model.forward(central_words[l], context_words[l], counts[l])
                    glove_model.backward(central_words[l], context_words[l])

                for l in range(N):
                    accum_loss += loss[l]

                description_list = []
                description_list.append(f"ITER={iteration+1:{len(str(iterations))}}")
                description_list.append(f"LOSS: {np.round(accum_loss/N, 4):.4f}")
                progress.set_description(', '.join(description_list))
                progress.update(1)

    def save_word2vec_format(self, path, index2word):
        """
        Save the model as gensim.models.KeyedVectors word2vec format.

        Args:
            path (str): A path to save file.
            num_epochs (dict): A index-to-word map.
        """
        from pathlib import Path
        output = Path(path)
        with output.open("w") as f:
            f.write(f"{self.W.shape[0]} {self.W.shape[1]}\n")
            for i in range(self.W.shape[0]):
                f.write(f"{index2word[i]} " + " ".join(list(map(str, self.W[i]))) + "\n")


@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True) 
def read_text(str fname, int min_count = 5, int window_size = 10):
    cdef dict w2i, i2w, count
    cdef str raw
    cdef list words
    cdef list lines
    cdef vector[vector[long]] x = []
    cdef vector[long] tmp = []
    cdef int i, j, k
    cdef long vocab_size, index
    cdef double[:,:] matrix
    cdef unordered_map[long, double] sparse_matrix
    cdef unordered_map[long, double].iterator _iterator
    cdef long[:] row, col
    cdef double[:] data

    with open(fname) as f:
        raw = f.read()
        words = raw.replace("\n", "<eos>").split(" ")
    count = dict(Counter(words))

    lines = raw.split("\n")

    w2i = {}
    i2w = {}
    for i in tqdm(range(len(lines)), ncols=100, leave=False):
        words = lines[i].split(" ")
        tmp = []
        for j in tqdm(range(len(words)), ncols=100, leave=False):
            if words[j] not in w2i and count[words[j]] >= min_count:
                index = len(w2i)
                w2i[words[j]] = index
                i2w[index] = words[j]
                tmp.push_back(index)
            elif count[words[j]] >= min_count:
                index = w2i[words[j]]
                tmp.push_back(index)
        x.push_back(tmp)

    vocab_size = len(w2i)

    for i in tqdm(range(len(x)), ncols=100, leave=False):
        for j in tqdm(range(len(x[i])), ncols=100, leave=False):
            for k in range(imax(0, j-window_size), j):
                sparse_matrix[x[i][j]+x[i][k]*vocab_size] += 1.0 / iabs(j - k)
                
    row = np.zeros(sparse_matrix.size(), dtype=np.int64)
    col = np.zeros(sparse_matrix.size(), dtype=np.int64)
    data = np.zeros(sparse_matrix.size())

    i = 0
    _iterator = sparse_matrix.begin()
    while _iterator != sparse_matrix.end():
        row[i] = dereference(_iterator).first % vocab_size
        col[i] = dereference(_iterator).first / vocab_size
        data[i] = dereference(_iterator).second
        postincrement(_iterator)
        i += 1
    ret = sparse.csr_matrix((data, (row, col)), shape=(vocab_size, vocab_size))
    return ret, i2w
