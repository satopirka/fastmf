# 
# Copyright (c) 2020 Minato Sato
# All rights reserved.
#
# This source code is licensed under the license found in the
# LICENSE file in the root directory of this source tree.
#

import cymf
import optuna
import numpy as np
import pandas as pd

import argparse
parser = argparse.ArgumentParser(description='')
parser.add_argument('--num_components', type=int, default=20)
parser.add_argument('--threads', type=int, default=8)
parser.add_argument('--trials', type=int, default=50)

args = parser.parse_args()

dataset = cymf.dataset.MovieLens("ml-100k")
Y_train = dataset.train.toarray()
Y_valid = dataset.valid.toarray()
Y_test = dataset.test.toarray()
valid_evaluator = cymf.evaluator.AverageOverAllEvaluator(Y_valid, Y_train, k=5, metrics=["DCG"])
test_evaluator = cymf.evaluator.AverageOverAllEvaluator(Y_test, Y_train, k=5)

def bpr_objective(trial: optuna.Trial):
    epochs = trial.suggest_int("epochs", 30, 100)
    alpha = trial.suggest_loguniform("alpha", 1e-5, 1e-1)
    weight_decay = trial.suggest_loguniform("weight_decay", 1e-4, 1e-1)
    model = cymf.BPR(num_components=args.num_components, learning_rate=alpha, weight_decay=weight_decay)
    model.fit(dataset.train, num_epochs=epochs, num_threads=args.threads, verbose=False)
    return valid_evaluator.evaluate(model.W@model.H.T)["DCG@5"]

def expomf_objective(trial: optuna.Trial):
    epochs = trial.suggest_int("epochs", 1, 5)
    weight_decay = trial.suggest_loguniform("weight_decay", 1e-4, 1e-1)
    model = cymf.ExpoMF(num_components=args.num_components, lam_y=weight_decay, weight_decay=weight_decay)
    model.fit(dataset.train, num_epochs=epochs, num_threads=args.threads, verbose=False)
    return valid_evaluator.evaluate(model.W@model.H.T)["DCG@5"]

def wmf_objective(trial: optuna.Trial):
    epochs = trial.suggest_int("epochs", 1, 30)
    weight_decay = trial.suggest_loguniform("weight_decay", 1e-4, 1e-1)
    weight = trial.suggest_loguniform("weight", 1, 30)
    model = cymf.WMF(num_components=args.num_components, weight_decay=weight_decay, weight=weight)
    model.fit(dataset.train, num_epochs=epochs, num_threads=args.threads, verbose=False)
    return valid_evaluator.evaluate(model.W@model.H.T)["DCG@5"]


summary = {}

study = optuna.create_study(direction="maximize")
study.optimize(bpr_objective, n_trials=args.trials)
print(study.best_params)
result = []
model = cymf.BPR(num_components=args.num_components, learning_rate=study.best_params["alpha"], weight_decay=study.best_params["weight_decay"])
model.fit(dataset.train, num_epochs=study.best_params["epochs"], num_threads=args.threads, verbose=False)
for i in range(5):
    result.append(test_evaluator.evaluate(model.W @ model.H.T))
summary["BPR"] = dict(pd.DataFrame(result).describe().loc[["mean", "std"]].T["mean"]) 
print(summary["BPR"])

study = optuna.create_study(direction="maximize")
study.optimize(expomf_objective, n_trials=args.trials)
print(study.best_params)
result = []
model = cymf.ExpoMF(num_components=args.num_components, lam_y=study.best_params["weight_decay"],weight_decay=study.best_params["weight_decay"])
model.fit(dataset.train, num_epochs=study.best_params["epochs"], verbose=False)
for i in range(5):
    result.append(test_evaluator.evaluate(model.W @ model.H.T))
summary["ExpoMF"] = dict(pd.DataFrame(result).describe().loc[["mean", "std"]].T["mean"]) 
print(summary["ExpoMF"])

study = optuna.create_study(direction="maximize")
study.optimize(wmf_objective, n_trials=args.trials)
print(study.best_params)
result = []
model = cymf.WMF(num_components=args.num_components, weight_decay=study.best_params["weight_decay"], weight=study.best_params["weight"])
model.fit(dataset.train, num_epochs=study.best_params["epochs"], num_threads=args.threads, verbose=False)
for i in range(5):
    result.append(test_evaluator.evaluate(model.W @ model.H.T))
summary["WMF"] = dict(pd.DataFrame(result).describe().loc[["mean", "std"]].T["mean"]) 
print(summary["WMF"])

print(pd.DataFrame(summary))
