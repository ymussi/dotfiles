;;; setup-defaults.el --- Defaults
;;; Commentary:
;;; Code:

;; fix old security emacs problems
(eval-after-load "enriched"
  '(defun enriched-decode-display-prop (start end &optional param)
     (list start end)))

;; garbage-collect on focus-out, emacs should feel snappier
(add-hook 'focus-out-hook #'garbage-collect)

(windmove-default-keybindings)

(defun push-mark-no-activate ()
  "Sometimes you just want to explicitly set a mark into one place.
so you can get back to it later with `pop-to-mark-command'"
  (interactive)
  (push-mark (point) t nil)
  (message "Pushed mark to ring."))

(setq-default
 ad-redefinition-action 'accept
 help-window-select t
 select-enable-clipboard t
 indent-tabs-mode nil)

;;; auto save when losing focus
(add-hook 'focus-out-hook (lambda () (save-some-buffers t)))

(setq echo-keystrokes 0.1
      line-number-mode t
      column-number-mode t
      enable-local-variables :safe
      load-prefer-newer t
      tab-always-indent 'complete
      delete-old-versions t
      vc-make-backup-files t
      save-place-mode t
      save-place-file (expand-file-name ".places" user-emacs-directory)
      global-auto-revert-non-file-buffers t
      auto-revert-verbose nil
      backup-by-copying t
      create-lockfiles nil
      shift-select-mode nil
      auto-save-file-name-transforms `((".*" ,temporary-file-directory t))
      backup-directory-alist `(("." . ,(concat user-emacs-directory
                                               "backups"))))

(add-hook 'after-init-hook 'delete-selection-mode)
(add-hook 'after-init-hook 'global-auto-revert-mode)
(add-hook 'after-init-hook 'savehist-mode)
(add-hook 'prog-mode-hook 'electric-pair-mode)
(add-hook 'prog-mode-hook 'show-paren-mode)

(use-package subword
  :diminish subword-mode
  :config
  (add-hook 'prog-mode-hook 'subword-mode))

(use-package abbrev
  :hook ((text-mode . abbrev-mode)
         (prog-mode . abbrev-mode))
  :diminish abbrev-mode
  :init
  (setq save-abbrevs 'silent))

(use-package recentf
  :config
  (setq-default recentf-max-saved-items 1000
                recentf-max-menu-items 15
                recentf-auto-cleanup 'never
                recentf-exclude '("/tmp/" "/ssh:"))
  (recentf-mode +1))


(setq uniquify-after-kill-buffer-p t
      uniquify-separator " • "
      uniquify-buffer-name-style 'reverse
      uniquify-ignore-buffers-re "^\\*")

(put 'erase-buffer 'disabled nil)

(use-package flyspell
  :diminish flyspell-mode
  :config
  (add-hook 'prog-mode-hook 'flyspell-prog-mode)
  (add-hook 'text-mode-hook 'flyspell-mode)
  (define-key flyspell-mode-map (kbd "C-,") nil))

;; to compare the contents of two test files, use M-x ediff-files.
;; open the two files you want to compare.
;; Press | to put the two files side by side
(setq ediff-window-setup-function 'ediff-setup-windows-plain)
(setq ediff-split-window-function (quote split-window-horizontally))

;;; utf-8 everywhere
(set-language-environment "UTF-8")
(set-default-coding-systems 'utf-8-unix)
(set-keyboard-coding-system 'utf-8)
(set-selection-coding-system 'utf-8)
(prefer-coding-system 'utf-8)

(use-package winner
  :init
  (setq winner-boring-buffers
        '("*Completions*"
          "*Compile-Log*"
          "*inferior-lisp*"
          "*Fuzzy Completions*"
          "*Apropos*"
          "*Help*"
          "*cvs*"
          "*Buffer List*"
          "*Ibuffer*"
          "*esh command on file*"))
  :config
  (winner-mode +1))

(provide 'setup-defaults)
;;; setup-defaults.el ends here
