# 
# Copyright (c) 2019 Minato Sato
# All rights reserved.
#
# This source code is licensed under the license found in the
# LICENSE file in the root directory of this source tree.
#

# cython: language_level=3

import cython
import multiprocessing
import numpy as np
from collections import Counter
from cython.parallel import prange
from cython.parallel import threadid
from sklearn import utils
from tqdm import tqdm

cimport numpy as np
from cython cimport floating
from cython cimport integral
from libcpp cimport bool
from libcpp.vector cimport vector
from libcpp.string cimport string
from libcpp.unordered_map cimport unordered_map

cdef extern from "math.h":
    double exp(double x) nogil
    double log(double x) nogil
    double log2(double x) nogil
    double sqrt(double x) nogil
    double pow(double x, double y) nogil

cdef inline floating sigmoid(floating x) nogil:
    return 1.0 / (1.0 + exp(-x))

cdef inline floating square(floating x) nogil:
    return x * x

class BPR(object):
    def __init__(self, int num_components,
                       floating learning_rate = 0.01,
                       floating weight_decay = 0.01):
        self.num_components = num_components
        self.learning_rate = learning_rate
        self.weight_decay = weight_decay

    def fit(self, X, X_valid = None, X_test = None,
                  int num_iterations = 10,
                  int num_threads = 8,
                  bool verbose = False):

        self.W = np.random.uniform(low=-0.1, high=0.1, size=(X.shape[0], self.num_components)) / self.num_components
        self.H = np.random.uniform(low=-0.1, high=0.1, size=(X.shape[1], self.num_components)) / self.num_components
        num_threads = min(num_threads, multiprocessing.cpu_count())

        users, positives = utils.shuffle(*(X.nonzero()))
        dense = np.array(X.todense())

        users_valid = None
        positives_valid = None
        dense_valid = None
        if X_valid is not None:
            users_valid, positives_valid = X_valid.nonzero()
            dense_valid = np.array(X_valid.todense())

        return fit_bpr(users, 
                       positives,
                       dense,
                       users_valid,
                       positives_valid,
                       dense_valid,
                       X_test.toarray() if X_test is not None else None,
                       self.W,
                       self.H,
                       num_iterations,
                       self.learning_rate,
                       self.weight_decay,
                       num_threads,
                       verbose)

@cython.boundscheck(False)
@cython.wraparound(False)
def fit_bpr(integral[:] users,
            integral[:] positives,
            np.ndarray[floating, ndim=2] X,
            integral[:] users_valid,
            integral[:] positives_valid,
            np.ndarray[floating, ndim=2] X_valid,
            np.ndarray[floating, ndim=2] X_test,
            floating[:,:] W, 
            floating[:,:] H, 
            int num_iterations, 
            floating learning_rate,
            floating weight_decay,
            int num_threads,
            bool verbose):
    cdef int iterations = num_iterations
    cdef int N = users.shape[0]
    cdef int K = W.shape[1]
    cdef int u, i, j, k, l, iteration
    cdef floating[:] loss = np.zeros(N)

    cdef unordered_map[string, double] metrics
    
    cdef list description_list

    cdef integral[:] negative_samples
    cdef integral[:,:] negatives = np.zeros((N, iterations)).astype(np.int32)
    cdef integral[:,:] negatives_valid = None

    cdef vector[unordered_map[string, double]] history = []

    cdef BprAdamUpdater updater = BprAdamUpdater(W, H, learning_rate, weight_decay)

    for l in range(N):
        u = users[l]
        negative_samples = np.random.choice((X[u]-1).nonzero()[0], iterations).astype(np.int32)
        negatives[l][:] = negative_samples

    if X_valid is not None:
        negatives_valid = np.zeros((users_valid.shape[0], iterations)).astype(np.int32)
        for l in range(users_valid.shape[0]):
            u = users_valid[l]
            negative_samples = np.random.choice((X_valid[u]-1).nonzero()[0], iterations).astype(np.int32)
            negatives_valid[l][:] = negative_samples

    with tqdm(total=iterations, leave=True, ncols=100, disable=not verbose) as progress:
        for iteration in range(iterations):
            metrics[b"loss"] = 0.0
            for l in prange(N, nogil=True, num_threads=num_threads):
                loss[l] = updater.loss(users[l], positives[l], negatives[l, iteration], update=True)

            for l in range(N):
                metrics[b"loss"] += loss[l]
            metrics[b"loss"] /= N

            if X_valid is not None:
                metrics[b"val_loss"] = 0.0
                for l in prange(users_valid.shape[0], nogil=True, num_threads=num_threads):
                    loss[l] = updater.loss(users_valid[l], positives_valid[l], negatives_valid[l, iteration], update=False)
                for l in range(users_valid.shape[0]):
                    metrics[b"val_loss"] += loss[l]
                metrics[b"val_loss"] /= users_valid.shape[0]

            description_list = []
            description_list.append(f"ITER={iteration+1:{len(str(iterations))}}")
            description_list.append(f"LOSS: {np.round(metrics[b'loss'], 4):.4f}")
            if X_valid is not None:
                description_list.append(f"VAL_LOSS: {np.round(metrics[b'val_loss'], 4):.4f}")

            if X_test is not None:
                metrics = evaluate(W, H, X_test, metrics)
            progress.set_description(', '.join(description_list))
            progress.update(1)

            history.push_back(metrics)
    return history


cdef class BprAdamUpdater(object):
    cdef public double[:,:] W
    cdef public double[:,:] H
    cdef public double[:,:] M_W
    cdef public double[:,:] V_W
    cdef public double[:,:] M_H
    cdef public double[:,:] V_H
    cdef public double alpha
    cdef public double beta1
    cdef public double beta2
    cdef public double epsilon
    cdef public double weight_decay
    def __init__(self, double[:,:] W, double[:,:] H, double learning_rate, double weight_decay):
        self.W = W
        self.H = H
        self.M_W = np.zeros(shape=(W.shape[0], W.shape[1]))
        self.V_W = np.zeros(shape=(W.shape[0], W.shape[1]))
        self.M_H = np.zeros(shape=(H.shape[0], H.shape[1]))
        self.V_H = np.zeros(shape=(H.shape[0], H.shape[1]))
        
        self.weight_decay = weight_decay
        self.alpha = learning_rate
        self.beta1 = 0.9
        self.beta2 = 0.999
        self.epsilon = 1e-8


    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef double loss(self, int u, int i, int j, bool update = True) nogil:
        cdef double x_uij, tmp, loss, l2_norm
        cdef int K = self.W.shape[1]
        cdef int k
        cdef double grad_wuk
        cdef double grad_hik
        cdef double grad_hjk

        x_uij = 0.0
        l2_norm = 0.0
        for k in range(K):
            x_uij += self.W[u, k] * (self.H[i, k] - self.H[j, k])
            l2_norm += square(self.W[u, k]) + square(self.H[i, k]) + square(self.H[j, k])

        loss = - log(sigmoid(x_uij)) + self.weight_decay * l2_norm
        
        if not update:
            return loss
        
        x_uij = (1.0 / (1.0 + exp(x_uij)))

        for k in range(K):
            grad_wuk = - (x_uij * (self.H[i, k] - self.H[j, k]) - self.weight_decay * self.W[u, k])
            grad_hik = - (x_uij *  self.W[u, k] - self.weight_decay * self.H[i, k])
            grad_hjk = - (x_uij * (-self.W[u, k]) - self.weight_decay * self.H[j, k])

            self.M_W[u, k] = self.beta1 * self.M_W[u, k] + (1 - self.beta1) * grad_wuk
            self.M_H[i, k] = self.beta1 * self.M_H[i, k] + (1 - self.beta1) * grad_hik
            self.M_H[j, k] = self.beta1 * self.M_H[j, k] + (1 - self.beta1) * grad_hjk

            self.V_W[u, k] = self.beta2 * self.V_W[u, k] + (1 - self.beta2) * square(grad_wuk)
            self.V_H[i, k] = self.beta2 * self.V_H[i, k] + (1 - self.beta2) * square(grad_hik)
            self.V_H[j, k] = self.beta2 * self.V_H[j, k] + (1 - self.beta2) * square(grad_hjk)

            self.W[u, k] -= self.alpha * (self.M_W[u, k] / (1 - self.beta1)) / (sqrt(self.V_W[u, k] / (1 - self.beta2)) + self.epsilon)
            self.H[i, k] -= self.alpha * (self.M_H[i, k] / (1 - self.beta1)) / (sqrt(self.V_H[i, k] / (1 - self.beta2)) + self.epsilon)
            self.H[j, k] -= self.alpha * (self.M_H[j, k] / (1 - self.beta1)) / (sqrt(self.V_H[j, k] / (1 - self.beta2)) + self.epsilon)
        
        return loss
                   

cdef class BprAdaGradUpdater(object):
    cdef public double[:,:] W
    cdef public double[:,:] H
    cdef public double[:,:] grad_accum_W
    cdef public double[:,:] grad_accum_H
    cdef public double weight_decay
    cdef public double learning_rate


    def __init__(self, double[:,:] W, double[:,:] H, double learning_rate, double weight_decay):
        self.W = W
        self.H = H
        self.grad_accum_W = np.ones(shape=(W.shape[0], W.shape[1]))
        self.grad_accum_H = np.ones(shape=(H.shape[0], H.shape[1]))
        self.weight_decay = weight_decay
        self.learning_rate = learning_rate

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef double loss(self, int u, int i, int j, bool update = True) nogil:
        cdef double x_uij, tmp, loss, l2_norm
        cdef int K = self.W.shape[1]
        cdef int k
        cdef double grad_wuk
        cdef double grad_hik
        cdef double grad_hjk

        x_uij = 0.0
        l2_norm = 0.0
        for k in range(K):
            x_uij += self.W[u, k] * (self.H[i, k] - self.H[j, k])
            l2_norm += square(self.W[u, k]) + square(self.H[i, k]) + square(self.H[j, k])

        loss = - log(sigmoid(x_uij)) + self.weight_decay * l2_norm
        
        if not update:
            return loss
        
        x_uij = (1.0 / (1.0 + exp(x_uij)))

        for k in range(K):
            grad_wuk = - (x_uij * (self.H[i, k] - self.H[j, k]) - self.weight_decay * self.W[u, k])
            grad_hik = - (x_uij *  self.W[u, k] - self.weight_decay * self.H[i, k])
            grad_hjk = - (x_uij * (-self.W[u, k]) - self.weight_decay * self.H[j, k])

            self.grad_accum_W[u, k] += square(grad_wuk)
            self.grad_accum_H[i, k] += square(grad_hik)
            self.grad_accum_H[j, k] += square(grad_hjk)

            self.W[u, k] -= self.learning_rate * grad_wuk / sqrt(self.grad_accum_W[u, k])
            self.H[i, k] -= self.learning_rate * grad_hik / sqrt(self.grad_accum_H[i, k])
            self.H[j, k] -= self.learning_rate * grad_hjk / sqrt(self.grad_accum_H[j, k])
        
        return loss
                   

@cython.boundscheck(False)
@cython.wraparound(False)
def evaluate(floating[:,:] W,
             floating[:,:] H,
             np.ndarray[floating, ndim=2] X,
             unordered_map[string, double] stores):
    cdef np.ndarray[floating, ndim=2] scores = np.dot(np.array(W), np.array(H).T)
    cdef np.ndarray[np.int_t, ndim=2] argsorted_scores = scores.argsort(axis=1)[:,::-1][:,:10]
    stores[b"Reacall@10"] = recall(argsorted_scores, X, k=10).mean()
    stores[b"nDCG@10"] = ndcg(argsorted_scores, X, k=10).mean()
    stores[b"MAP@10"] = ap(argsorted_scores, X, k=10).mean()
    return stores

@cython.boundscheck(False)
@cython.wraparound(False)
def recall(integral[:,:] argsorted_scores, floating[:,:] X, int k = 10, int num_threads = 1):
    cdef int N = X.shape[0]
    cdef floating[:] _sum = np.array(X).sum(axis=1)
    cdef int i, j

    cdef floating[:] ret = np.zeros(shape=(N,))

    for i in range(N):
        if _sum[i] == 0:
            ret[i] = 0.0
            continue
        for j in range(k):
            ret[i] += X[i, argsorted_scores[i, j]]
        ret[i] /= _sum[i]

    return np.array(ret)

@cython.boundscheck(False)
@cython.wraparound(False)
def ndcg(integral[:,:] argsorted_scores, floating[:,:] X, int k = 10, int num_threads = 1):
    cdef int N = X.shape[0]
    cdef floating[:] _sum = np.array(X).sum(axis=1)
    cdef int i, j
    cdef floating[:] tmp = np.zeros(N)

    cdef floating[:] ret = np.zeros(shape=(N,))

    for i in range(N):
        if _sum[i] == 0:
            ret[i] = 0.0
            continue

        tmp[i] = 1.0
        for j in range(1, <int>min(_sum[i], k)):
            tmp[i] += 1.0 / log2(j+1)

        ret[i] = X[i, argsorted_scores[i, 0]]
        for j in range(1, k):
            ret[i] += X[i, argsorted_scores[i, j]] / log2(j+1)

        ret[i] /= tmp[i]

    return np.array(ret)

@cython.boundscheck(False)
@cython.wraparound(False)
def ap(integral[:,:] argsorted_scores, floating[:,:] X, int k = 10, int num_threads = 1):
    cdef int N = X.shape[0]
    cdef int i, j
    cdef floating[:] counter = np.zeros(N)
    cdef floating[:] rating = np.zeros(N)

    cdef floating[:] ret = np.zeros(shape=(N,))

    for i in range(N):
        counter[i] = 0.0

        for j in range(k):
            rating[i] = X[i, argsorted_scores[i, j]]
            if rating[i] == 1.0:
                counter[i] += 1.0
                ret[i] += counter[i] / (j + 1)

        if counter[i] == 0.0:
            ret[i] = 0.0
            continue
        ret[i] /= counter[i]

    return np.array(ret)