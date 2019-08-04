;;; setup-git.el --- git
;;; Commentary:
;;; Code:

(use-package browse-at-remote :ensure t)
(use-package gitconfig-mode :ensure t)
(use-package git-timemachine :ensure t)
(use-package diff-hl :ensure t)
(use-package magit
  :ensure t
  :init
  (setq magit-no-confirm '(stage-all-changes
                           unstage-all-changes))
  (setq magit-completing-read-function 'magit-ido-completing-read))

(add-to-list 'auto-mode-alist '("\\.gitconfig$" . gitconfig-mode))
(add-to-list 'auto-mode-alist '("\\.gitignore$" . gitignore-mode))

;; diff
(add-hook 'magit-post-refresh-hook 'diff-hl-magit-post-refresh)
(add-hook 'after-init-hook 'global-diff-hl-mode)


(provide 'setup-git)
;;; setup-git.el ends here
