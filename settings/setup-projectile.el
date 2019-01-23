;;; setup-projectile --- Projects
;;; Commentary:

;; Manage your projects

;;; Code:

(bk/install-maybe 'projectile)
(require 'projectile)

(setq-default projectile-mode-line-prefix " Proj")
(setq projectile-mode-line-function '(lambda () (format " Proj[%s]" (projectile-project-name))))

(setq projectile-completion-system 'ido
      projectile-switch-project-action 'projectile-find-file
      projectile-project-search-path '("~/captalys" "~/personal"))


(eval-after-load 'projectile
  '(define-key projectile-mode-map (kbd "C-c p") 'projectile-command-map))

(add-hook 'after-init-hook #'projectile-mode)

(provide 'setup-projectile)
;;; setup-projectile.el ends here
