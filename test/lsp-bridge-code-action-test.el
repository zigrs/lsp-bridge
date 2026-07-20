;;; lsp-bridge-code-action-test.el --- Code action tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)

;; The tests below exercise command dispatch only; avoid loading the optional
;; popup/completion dependencies in a clean batch Emacs.
(provide 'acm)
(provide 'acm-frame)
(provide 'lsp-bridge-call-hierarchy)

(load-file
 (expand-file-name "../lsp-bridge-code-action.el"
                   (file-name-directory (or load-file-name buffer-file-name))))
(load-file
 (expand-file-name "../acm/acm-backend-lsp.el"
                   (file-name-directory (or load-file-name buffer-file-name))))

(ert-deftest lsp-bridge-code-action-applies-gopls-split-lines-edits-in-order ()
  (with-temp-buffer
    (insert "package splitrepro\n\nfunc add(a int, b int) int { return a + b }\n")
    ;; gopls returns these edits in open-paren, close-paren, separator order.
    (acm-backend-lsp-apply-text-edits
     '((:range (:start (:line 2 :character 9)
                       :end (:line 2 :character 9))
        :newText "\n\t")
       (:range (:start (:line 2 :character 21)
                       :end (:line 2 :character 21))
        :newText ",\n")
       (:range (:start (:line 2 :character 14)
                       :end (:line 2 :character 16))
        :newText ",\n\t")))
    (should
     (equal (buffer-string)
            "package splitrepro\n\nfunc add(\n\ta int,\n\tb int,\n) int { return a + b }\n"))))

(ert-deftest lsp-bridge-code-action-preview-does-not-execute-command ()
  (let ((action '(:title "Split" :server-name "test-ls"
                  :command "test.split" :arguments ("argument")))
        calls)
    (cl-letf (((symbol-function 'lsp-bridge-call-file-api)
               (lambda (&rest args) (push args calls)))
              ((symbol-function 'lsp-bridge-diagnostic-hide-overlays)
               #'ignore))
      (with-temp-buffer
        (lsp-bridge-code-action--fix-do action (current-buffer)))
      (should-not calls)

      (lsp-bridge-code-action--fix-do action)
      (should (equal calls
                     '(("execute_command" "test-ls" "test.split"
                        ("argument"))))))))

(provide 'lsp-bridge-code-action-test)

;;; lsp-bridge-code-action-test.el ends here
